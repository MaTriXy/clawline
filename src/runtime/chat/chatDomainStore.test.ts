import {
  createMemoryChatPersistence
} from "../persistence/indexedDbChatPersistence";
import { createChatDomainStore } from "./chatDomainStore";
import { phase1TranscriptFixture } from "../../test/fixtures/transcripts/phase1-transcript";

async function waitForHydration(store: ReturnType<typeof createChatDomainStore>) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (store.getState().hydrated) {
      return;
    }
    await new Promise((resolve) => window.setTimeout(resolve, 0));
  }
  throw new Error("Store did not hydrate");
}

describe("chatDomainStore", () => {
  it("reconciles optimistic send -> ack -> echoed user replacement", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.enqueueOptimisticMessage({
      content: "Hello",
      deviceId: "browser-device-1",
      id: "c_1",
      sessionKey: "agent:main:clawline:user_1:main",
      timestamp: 100
    });
    store.markMessageAcked("c_1");
    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_1",
          role: "user",
          content: "Hello",
          timestamp: 101,
          streaming: false,
          deviceId: "browser-device-1",
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );

    const messages =
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"];

    expect(messages).toHaveLength(1);
    expect(messages[0].id).toBe("s_1");
    expect(messages[0].delivery).toBe("server");
  });

  it("updates streaming assistant replies in place", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_stream",
          role: "assistant",
          content: "Hel",
          timestamp: 100,
          streaming: true,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );
    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_stream",
          role: "assistant",
          content: "Hello",
          timestamp: 101,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );

    const messages =
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"];

    expect(messages).toHaveLength(1);
    expect(messages[0].content).toBe("Hello");
    expect(messages[0].streaming).toBe(false);
  });

  it("applies stream and provisioning snapshots through the domain owner", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applySessionInfo({
      type: "session_info",
      sessionKeys: ["agent:main:clawline:user_1:main"]
    });
    store.applyStreamSnapshot([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);

    expect(store.getState().streams).toEqual([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);
  });

  it("hydrates snapshots without generating unread state or replay duplicates", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(store);

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_101",
          role: "assistant",
          content: "Hi there",
          timestamp: 1704672000000,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "replay"
      },
    );

    expect(
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(2);
    expect(store.getState().unreadBySessionKey).toEqual({});
  });

  it("treats hydrate as gap fill and does not overwrite live replayed state", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_live",
          role: "assistant",
          content: "fresh replayed copy",
          timestamp: 1704673000000,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "replay"
      },
    );

    await waitForHydration(store);

    expect(
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toEqual([
      expect.objectContaining({
        id: "s_live",
        content: "fresh replayed copy"
      })
    ]);
  });

  it("marks non-active live assistant messages unread and clears them on selection", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_1",
        role: "assistant",
        content: "Side reply",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });
    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_2",
        role: "assistant",
        content: "Another side reply",
        timestamp: 102,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });

    expect(store.getState().unreadBySessionKey).toEqual({
      "agent:main:clawline:user_1:side": 2
    });
    expect(store.getState().firstUnreadMessageIdBySessionKey).toEqual({
      "agent:main:clawline:user_1:side": "s_side_1"
    });

    store.markSessionRead("agent:main:clawline:user_1:side");

    expect(store.getState().unreadBySessionKey).toEqual({});
    expect(store.getState().firstUnreadMessageIdBySessionKey).toEqual({});
    expect(
      store.getState().replayCursorsBySessionKey["agent:main:clawline:user_1:side"]
    ).toEqual({
      lastReadMessageId: "s_side_2"
    });
  });
});
