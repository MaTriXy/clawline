import { createAuthSessionStore } from "../auth/authSessionStore";
import { createChatDomainStore } from "../chat/chatDomainStore";
import { createMemoryChatPersistence } from "../persistence/indexedDbChatPersistence";
import { createTransportMachine } from "./transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";

function seedSession() {
  const authStore = createAuthSessionStore();
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });
  return authStore;
}

describe("transportMachine", () => {
  it("transitions idle -> connecting -> authenticating -> live on auth success", () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    expect(transport.getState().phase).toBe("connecting");
    expect(factory.sockets).toHaveLength(1);

    factory.sockets[0].emitOpen();
    expect(transport.getState().phase).toBe("authenticating");
    expect(JSON.parse(factory.sockets[0].sentTexts[0]).type).toBe("auth");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("live");
    expect(chatStore.getState().streams[0]?.sessionKey).toBe(
      "agent:main:clawline:user_1:main"
    );
  });

  it("suppresses duplicate reconnect intents while already live", () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );

    transport.retryNow();
    transport.retryNow();

    expect(factory.sockets).toHaveLength(1);
    expect(transport.getState().phase).toBe("live");
  });

  it("transitions to failed and clears auth on auth failure", () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: false,
        reason: "auth_failed"
      })
    );

    expect(transport.getState().phase).toBe("failed");
    expect(authStore.getState().session).toBeNull();
  });

  it("allows manual retry out of recovery", () => {
    vi.useFakeTimers();

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );
    factory.sockets[0].emitClose();

    expect(transport.getState().phase).toBe("recovering");

    transport.retryNow();
    expect(factory.sockets).toHaveLength(2);

    vi.useRealTimers();
  });

  it("keeps tab transport independent across two runtimes", () => {
    const authStoreA = seedSession();
    const authStoreB = seedSession();
    const chatStoreA = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const chatStoreB = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factoryA = new FakeWebSocketFactory();
    const factoryB = new FakeWebSocketFactory();

    const transportA = createTransportMachine({
      authSessionStore: authStoreA,
      chatDomainStore: chatStoreA,
      webSocketFactory: factoryA.create
    });
    const transportB = createTransportMachine({
      authSessionStore: authStoreB,
      chatDomainStore: chatStoreB,
      webSocketFactory: factoryB.create
    });

    factoryA.sockets[0].emitOpen();
    factoryB.sockets[0].emitOpen();
    factoryA.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );
    factoryB.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );

    expect(transportA.getState().phase).toBe("live");
    expect(transportB.getState().phase).toBe("live");
    expect(factoryA.sockets).toHaveLength(1);
    expect(factoryB.sockets).toHaveLength(1);
  });
});
