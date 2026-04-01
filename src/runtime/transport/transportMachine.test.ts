import { createAuthSessionStore } from "../auth/authSessionStore";
import { createChatDomainStore } from "../chat/chatDomainStore";
import { createMemoryChatPersistence } from "../persistence/indexedDbChatPersistence";
import { createTransportMachine } from "./transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";

class FakeBrowserRuntime {
  isCurrentlyOnline = true;
  listeners = {
    offline: new Set<() => void>(),
    online: new Set<() => void>()
  };
  nextTimeoutId = 1;
  pendingTimeouts = new Map<number, () => void>();

  addEventListener(type: "offline" | "online", listener: () => void) {
    this.listeners[type].add(listener);
    return () => {
      this.listeners[type].delete(listener);
    };
  }

  clearTimeout(timeoutId: number) {
    this.pendingTimeouts.delete(timeoutId);
  }

  emit(type: "offline" | "online") {
    if (type === "offline") {
      this.isCurrentlyOnline = false;
    } else {
      this.isCurrentlyOnline = true;
    }

    for (const listener of this.listeners[type]) {
      listener();
    }
  }

  isOnline() {
    return this.isCurrentlyOnline;
  }

  setTimeout(listener: () => void) {
    const timeoutId = this.nextTimeoutId;
    this.nextTimeoutId += 1;
    this.pendingTimeouts.set(timeoutId, listener);
    return timeoutId;
  }
}

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

  it("waits for the browser to come back online before reconnecting", () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const browserRuntime = new FakeBrowserRuntime();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      browserRuntime,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );

    browserRuntime.emit("offline");

    expect(transport.getState()).toMatchObject({
      failureReason: "Browser offline",
      isBrowserOnline: false,
      phase: "recovering"
    });
    expect(factory.sockets).toHaveLength(1);

    browserRuntime.emit("online");

    expect(transport.getState().isBrowserOnline).toBe(true);
    expect(factory.sockets).toHaveLength(2);
  });
});
