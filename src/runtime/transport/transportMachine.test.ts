import { createAuthSessionStore } from "../auth/authSessionStore";
import { createChatDomainStore } from "../chat/chatDomainStore";
import { createMemoryChatPersistence } from "../persistence/indexedDbChatPersistence";
import { createTransportMachine } from "./transportMachine";
import { FakeCrossTabHub } from "../../test/support/fakeCrossTabChannel";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";

class FakeBrowserRuntime {
  isCurrentlyOnline = true;
  listeners = {
    offline: new Set<() => void>(),
    online: new Set<() => void>()
  };

  addEventListener(type: "offline" | "online", listener: () => void) {
    this.listeners[type].add(listener);
    return () => {
      this.listeners[type].delete(listener);
    };
  }

  clearTimeout(timeoutId: number) {
    window.clearTimeout(timeoutId);
  }

  clearInterval(intervalId: number) {
    window.clearInterval(intervalId);
  }

  emit(type: "offline" | "online") {
    this.isCurrentlyOnline = type === "online";

    for (const listener of this.listeners[type]) {
      listener();
    }
  }

  isOnline() {
    return this.isCurrentlyOnline;
  }

  now() {
    return Date.now();
  }

  setInterval(listener: () => void, delayMs: number) {
    return window.setInterval(listener, delayMs);
  }

  setTimeout(listener: () => void, delayMs: number) {
    return window.setTimeout(listener, delayMs);
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

function setupSingleRuntime() {
  vi.useFakeTimers();

  const authStore = seedSession();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const factory = new FakeWebSocketFactory();
  const hub = new FakeCrossTabHub();
  const transport = createTransportMachine({
    authSessionStore: authStore,
    browserRuntime: new FakeBrowserRuntime(),
    crossTabChannel: hub.createChannel("peer-a"),
    chatDomainStore: chatStore,
    selectedSessionKeySource: () => "agent:main:clawline:user_1:main",
    webSocketFactory: factory.create
  });

  vi.advanceTimersByTime(300);

  return {
    authStore,
    chatStore,
    factory,
    transport
  };
}

describe("transportMachine", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("transitions idle -> connecting -> authenticating -> live on auth success", () => {
    const { chatStore, factory, transport } = setupSingleRuntime();

    expect(transport.getState()).toMatchObject({
      ownership: "leader",
      phase: "connecting"
    });
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
    const { factory, transport } = setupSingleRuntime();

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
    const { authStore, factory, transport } = setupSingleRuntime();

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
    const { factory, transport } = setupSingleRuntime();

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );
    factory.sockets[0].emitClose();

    expect(transport.getState().phase).toBe("recovering");

    transport.retryNow();
    expect(factory.sockets).toHaveLength(2);
  });

  it("shares one leader-owned socket and mirrors follower sends", async () => {
    vi.useFakeTimers();

    const authStoreA = seedSession();
    const authStoreB = seedSession();
    const chatStoreA = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const chatStoreB = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const hub = new FakeCrossTabHub();

    const transportA = createTransportMachine({
      authSessionStore: authStoreA,
      browserRuntime: new FakeBrowserRuntime(),
      crossTabChannel: hub.createChannel("peer-b"),
      chatDomainStore: chatStoreA,
      selectedSessionKeySource: () => "agent:main:clawline:user_1:main",
      webSocketFactory: factory.create
    });
    const transportB = createTransportMachine({
      authSessionStore: authStoreB,
      browserRuntime: new FakeBrowserRuntime(),
      crossTabChannel: hub.createChannel("peer-c"),
      chatDomainStore: chatStoreB,
      selectedSessionKeySource: () => "agent:main:clawline:user_1:main",
      webSocketFactory: factory.create
    });

    vi.advanceTimersByTime(300);

    expect(factory.sockets).toHaveLength(1);

    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );

    expect(transportA.getState().phase).toBe("live");
    expect(transportB.getState().phase).toBe("live");
    expect(
      [transportA.getState().ownership, transportB.getState().ownership].sort()
    ).toEqual(["follower", "leader"]);

    const follower =
      transportA.getState().ownership === "follower" ? transportA : transportB;
    const leaderStore =
      transportA.getState().ownership === "leader" ? chatStoreA : chatStoreB;
    const followerStore =
      transportA.getState().ownership === "follower" ? chatStoreA : chatStoreB;

    await follower.sendMessage({
      content: "hello from follower",
      id: "c_shared_1",
      sessionKey: "agent:main:clawline:user_1:main",
      timestamp: 100
    });

    expect(factory.sockets[0].sentTexts).toContain(
      JSON.stringify({
        type: "message",
        id: "c_shared_1",
        content: "hello from follower",
        attachments: [],
        sessionKey: "agent:main:clawline:user_1:main"
      })
    );
    expect(
      leaderStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(1);
    expect(
      followerStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(1);

    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "ack", id: "c_shared_1" })
    );
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_shared_1",
        role: "user",
        content: "hello from follower",
        timestamp: 101,
        streaming: false,
        deviceId: "browser-device-1",
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      })
    );

    expect(
      leaderStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"][0]
        ?.id
    ).toBe("s_shared_1");
    expect(
      followerStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"][0]
        ?.id
    ).toBe("s_shared_1");
  });

  it("waits for the browser to come back online before reconnecting", () => {
    vi.useFakeTimers();

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const browserRuntime = new FakeBrowserRuntime();
    const hub = new FakeCrossTabHub();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      browserRuntime,
      crossTabChannel: hub.createChannel("peer-a"),
      chatDomainStore: chatStore,
      selectedSessionKeySource: () => "agent:main:clawline:user_1:main",
      webSocketFactory: factory.create
    });

    vi.advanceTimersByTime(300);
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
    vi.advanceTimersByTime(300);

    expect(transport.getState().isBrowserOnline).toBe(true);
    expect(factory.sockets).toHaveLength(2);
  });
});
