import { useEffect, useMemo, useState, type KeyboardEvent } from "react";
import { Reply, SendHorizontal, X } from "lucide-react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import {
  type CrossChatNotificationBubble,
  useCrossChatNotificationStore
} from "../../runtime/chat/crossChatNotificationStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";

const VISIBLE_NOTIFICATION_LIMIT = 10;

export function CrossChatNotificationOverlay() {
  const { state: authState } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: notificationState, store: notificationStore } =
    useCrossChatNotificationStore();
  const { store: transportStore } = useTransportMachine();
  const [replyErrorsBySourceChatId, setReplyErrorsBySourceChatId] = useState<
    Record<string, string>
  >({});
  const orderedBubbles = useMemo(
    () =>
      Object.values(notificationState.bubblesBySourceChatId).sort(
        sortBubblesByRecentActivity
      ),
    [notificationState.bubblesBySourceChatId]
  );
  const visibleBubbles = orderedBubbles.slice(0, VISIBLE_NOTIFICATION_LIMIT);
  const overflowBubbles = orderedBubbles.slice(VISIBLE_NOTIFICATION_LIMIT);
  const visibleSourceChatIds = visibleBubbles.map((bubble) => bubble.sourceChatId);

  useEffect(() => {
    for (const bubble of overflowBubbles) {
      if (bubble.replyMode || bubble.replyDraft.length > 0) {
        notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
      }
    }
  }, [notificationStore, overflowBubbles]);

  useEffect(() => {
    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.defaultPrevented || event.altKey || event.ctrlKey || !event.metaKey) {
        return;
      }

      const key = shortcutKeyFromEvent(event);
      if (key === "-" && !event.shiftKey) {
        event.preventDefault();
        notificationStore.clearCrossChatNotifications();
        return;
      }

      const hotkeyIndex = hotkeyIndexFromKey(key);
      if (hotkeyIndex === null) {
        return;
      }

      const sourceChatId = visibleSourceChatIds[hotkeyIndex];
      if (!sourceChatId) {
        return;
      }

      event.preventDefault();
      if (event.shiftKey) {
        notificationStore.openCrossChatNotificationReply(sourceChatId);
      } else {
        notificationStore.dismissCrossChatNotification(sourceChatId);
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [notificationStore, visibleSourceChatIds]);

  if (visibleBubbles.length === 0) {
    return null;
  }

  async function sendReply(bubble: CrossChatNotificationBubble) {
    const submitSession = authState.session;
    const content = bubble.replyDraft.trim();
    if (!submitSession || content.length === 0) {
      return;
    }

    setReplyErrorsBySourceChatId((current) => {
      const next = { ...current };
      delete next[bubble.sourceChatId];
      return next;
    });

    const id = `c_${generateUuidV4()}`;
    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content,
      deviceId: submitSession.deviceId,
      id,
      sessionKey: bubble.sourceChatId,
      timestamp: Date.now(),
      wireAttachments: []
    });

    try {
      await transportStore.sendMessage({
        attachments: [],
        content,
        id,
        sessionKey: bubble.sourceChatId
      });
      notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
    } catch {
      chatStore.markMessageFailed(id);
      setReplyErrorsBySourceChatId((current) => ({
        ...current,
        [bubble.sourceChatId]: "Reply send failed."
      }));
    }
  }

  return (
    <aside
      aria-label="Cross-chat notifications"
      className="cross-chat-notification-overlay"
    >
      {visibleBubbles.map((bubble, index) => (
        <section
          aria-label={`${bubble.sourceTitle} notification`}
          className="cross-chat-notification-bubble"
          data-testid="cross-chat-notification-bubble"
          key={bubble.sourceChatId}
        >
          <header className="cross-chat-notification-header">
            <div className="cross-chat-notification-title">
              <kbd>{index}</kbd>
              <strong>{bubble.sourceTitle}</strong>
            </div>
            <div className="cross-chat-notification-actions">
              <button
                aria-label="Reply"
                className="cross-chat-notification-icon-button"
                onClick={() =>
                  notificationStore.openCrossChatNotificationReply(bubble.sourceChatId)
                }
                type="button"
              >
                <Reply aria-hidden="true" size={15} strokeWidth={2.2} />
              </button>
              <button
                aria-label="Dismiss"
                className="cross-chat-notification-icon-button"
                onClick={() =>
                  notificationStore.dismissCrossChatNotification(bubble.sourceChatId)
                }
                type="button"
              >
                <X aria-hidden="true" size={16} strokeWidth={2.3} />
              </button>
            </div>
          </header>
          <div className="cross-chat-notification-entries">
            {bubble.entriesNewestFirst.map((entry) => (
              <p key={entry.assistantMessageId}>
                {entry.contentPreview.length > 0 ? entry.contentPreview : "Assistant reply"}
              </p>
            ))}
          </div>
          {bubble.replyMode ? (
            <div className="cross-chat-notification-reply">
              <textarea
                aria-label={`Reply to ${bubble.sourceTitle}`}
                onChange={(event) =>
                  notificationStore.setCrossChatNotificationReplyDraft(
                    bubble.sourceChatId,
                    event.target.value
                  )
                }
                onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => {
                  if (event.key === "Escape") {
                    event.preventDefault();
                    notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
                    return;
                  }
                  if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    void sendReply(bubble);
                  }
                }}
                rows={1}
                value={bubble.replyDraft}
              />
              <button
                aria-label={`Send reply to ${bubble.sourceTitle}`}
                className="cross-chat-notification-icon-button cross-chat-notification-send"
                onClick={() => void sendReply(bubble)}
                type="button"
              >
                <SendHorizontal aria-hidden="true" size={15} strokeWidth={2.2} />
              </button>
              {replyErrorsBySourceChatId[bubble.sourceChatId] ? (
                <p className="field-error">
                  {replyErrorsBySourceChatId[bubble.sourceChatId]}
                </p>
              ) : null}
            </div>
          ) : null}
        </section>
      ))}
    </aside>
  );
}

function sortBubblesByRecentActivity(
  left: CrossChatNotificationBubble,
  right: CrossChatNotificationBubble
) {
  if (left.lastAssistantActivityAt !== right.lastAssistantActivityAt) {
    return right.lastAssistantActivityAt - left.lastAssistantActivityAt;
  }
  return left.sourceChatId.localeCompare(right.sourceChatId);
}

function hotkeyIndexFromKey(key: string) {
  if (!/^[0-9]$/.test(key)) {
    return null;
  }
  return Number(key);
}

function shortcutKeyFromEvent(event: globalThis.KeyboardEvent) {
  if (/^Digit[0-9]$/.test(event.code)) {
    return event.code.slice("Digit".length);
  }

  if (/^Numpad[0-9]$/.test(event.code)) {
    return event.code.slice("Numpad".length);
  }

  if (event.code === "Minus" || event.code === "NumpadSubtract") {
    return "-";
  }

  return event.key.toLowerCase();
}
