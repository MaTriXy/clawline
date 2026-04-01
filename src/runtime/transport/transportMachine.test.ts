import { createAuthSessionStore } from "../auth/authSessionStore";
import { createChatDomainStore } from "../chat/chatDomainStore";
import { createMemoryChatPersistence } from "../persistence/indexedDbChatPersistence";
import { createTransportMachine } from "./transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";
import { phase1TranscriptFixture } from "../../test/fixtures/transcripts/phase1-transcript";

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

async function waitForSocket(factory: FakeWebSocketFactory, count = 1) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (factory.sockets.length >= count) {
      return;
    }
    await Promise.resolve();
  }

  throw new Error(`Expected ${count} socket(s), found ${factory.sockets.length}`);
}

describe("transportMachine", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("transitions idle -> connecting -> authenticating -> live on auth success", async () => {
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

    await waitForSocket(factory);

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

  it("stays replaying until replay messages complete even after auth succeeds", async () => {
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

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 1,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("replaying");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_101",
        role: "assistant",
        content: "Replay complete",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      })
    );

    expect(transport.getState().phase).toBe("live");
  });

  it("waits for provisioning before entering live when auth result has no session inventory", async () => {
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

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 0
      })
    );

    expect(transport.getState().phase).toBe("replaying");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "session_info",
        userId: "user_1",
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("live");
  });

  it("sends persisted per-stream replay cursors on auth bootstrap", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    chatStore.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_main_1",
        role: "assistant",
        content: "Main",
        timestamp: 100,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "replay"
    });
    chatStore.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_1",
        role: "assistant",
        content: "Side",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "replay"
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();

    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      type: "auth",
      lastMessageId: "s_side_1",
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": "s_main_1",
        "agent:main:clawline:user_1:side": "s_side_1"
      }
    });
  });

  it("suppresses duplicate reconnect intents while already live", async () => {
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

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    transport.retryNow();
    transport.retryNow();

    expect(factory.sockets).toHaveLength(1);
    expect(transport.getState().phase).toBe("live");
  });

  it("transitions to failed and clears auth on auth failure", async () => {
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

    await waitForSocket(factory);
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

  it("allows manual retry out of recovery", async () => {
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

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );
    factory.sockets[0].emitClose();

    expect(transport.getState().phase).toBe("recovering");

    transport.retryNow();
    expect(factory.sockets).toHaveLength(2);
  });

  it("keeps tab transport independent across two runtimes", async () => {
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

    await waitForSocket(factoryA);
    await waitForSocket(factoryB);
    factoryA.sockets[0].emitOpen();
    factoryB.sockets[0].emitOpen();
    factoryA.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );
    factoryB.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transportA.getState().phase).toBe("live");
    expect(transportB.getState().phase).toBe("live");
    expect(factoryA.sockets).toHaveLength(1);
    expect(factoryB.sockets).toHaveLength(1);
  });

  it("waits for the browser to come back online before reconnecting", async () => {
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

    await waitForSocket(factory);
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

  it("waits for persisted hydration before auth bootstrap on restored sessions", async () => {
    const authStore = seedSession();
    let resolveLoad: ((snapshot: typeof phase1TranscriptFixture | null) => void) | null =
      null;
    const chatStore = createChatDomainStore({
      persistence: {
        clear: async () => undefined,
        load: () =>
          new Promise((resolve) => {
            resolveLoad = resolve;
          }),
        save: async () => undefined
      }
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    expect(factory.sockets).toHaveLength(0);
    expect(chatStore.getState().hydrated).toBe(false);

    const hydrateResolver = resolveLoad;
    if (!hydrateResolver) {
      throw new Error("Expected hydrate resolver to be captured");
    }

    (
      hydrateResolver as (snapshot: typeof phase1TranscriptFixture | null) => void
    )(phase1TranscriptFixture);
    await Promise.resolve();
    await Promise.resolve();

    expect(chatStore.getState().hydrated).toBe(true);
    expect(factory.sockets).toHaveLength(1);

    factory.sockets[0].emitOpen();
    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      lastMessageId: "s_101"
    });
  });
});
