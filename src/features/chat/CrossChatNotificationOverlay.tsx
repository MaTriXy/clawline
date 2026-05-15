import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent
} from "react";
import { Reply, SendHorizontal, X } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import {
  type CrossChatNotificationBubble,
  useCrossChatNotificationStore
} from "../../runtime/chat/crossChatNotificationStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";

const VISIBLE_NOTIFICATION_LIMIT = 10;
const OVERLAY_VERTICAL_MARGIN_PX = 14;
const NOTIFICATION_MAX_BUBBLE_HEIGHT_PX = 240;
const NOTIFICATION_MAX_BUBBLE_VIEWPORT_RATIO = 0.34;
const NOTIFICATION_BUBBLE_GAP_PX = 9;
const COLLAPSE_SWIPE_THRESHOLD_PX = 44;
const CLEAR_ALL_HOLD_DELAY_MS = 650;
const NOTIFICATION_EXIT_ANIMATION_MS = 180;

interface RenderedNotificationBubble {
  bubble: CrossChatNotificationBubble;
  isExiting: boolean;
}

export function CrossChatNotificationOverlay() {
  const navigate = useNavigate();
  const { state: authState } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: notificationState, store: notificationStore } =
    useCrossChatNotificationStore();
  const { store: transportStore } = useTransportMachine();
  const [replyErrorsBySourceChatId, setReplyErrorsBySourceChatId] = useState<
    Record<string, string>
  >({});
  const [visibleCapacity, setVisibleCapacity] = useState(() =>
    visibleCapacityForViewportHeight(getViewportHeight())
  );
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [renderedBubbles, setRenderedBubbles] = useState<RenderedNotificationBubble[]>(
    []
  );
  const [activeSourceChatId, setActiveSourceChatId] = useState<string | null>(null);
  const dragStartXRef = useRef<number | null>(null);
  const dragStartYRef = useRef<number | null>(null);
  const suppressNavigationClickRef = useRef(false);
  const clearAllHoldTimerRef = useRef<number | null>(null);
  const entriesRefsBySourceChatId = useRef<Record<string, HTMLDivElement | null>>({});
  const orderedBubbles = useMemo(
    () =>
      Object.values(notificationState.bubblesBySourceChatId).sort(
        sortBubblesByRecentActivity
      ),
    [notificationState.bubblesBySourceChatId]
  );
  const visibleBubbles = orderedBubbles.slice(0, visibleCapacity);
  const overflowBubbles = orderedBubbles.slice(visibleCapacity);
  const visibleSourceChatIds = visibleBubbles.map((bubble) => bubble.sourceChatId);
  const visibleBubbleSignature = visibleBubbles
    .map(
      (bubble) =>
        `${bubble.sourceChatId}:${bubble.lastAssistantActivityAt}:${bubble.replyMode}:${bubble.replyDraft}:${bubble.entriesNewestFirst.map((entry) => `${entry.assistantMessageId}:${entry.updatedAt}`).join(",")}`
    )
    .join("|");

  useEffect(() => {
    function updateVisibleCapacity() {
      setVisibleCapacity(visibleCapacityForViewportHeight(getViewportHeight()));
    }

    updateVisibleCapacity();
    window.addEventListener("resize", updateVisibleCapacity);
    return () => window.removeEventListener("resize", updateVisibleCapacity);
  }, []);

  useEffect(() => {
    const visibleSourceChatIdSet = new Set(
      visibleBubbles.map((bubble) => bubble.sourceChatId)
    );
    setRenderedBubbles((current) => {
      const exitingBubbles = current
        .filter((item) => !visibleSourceChatIdSet.has(item.bubble.sourceChatId))
        .map((item) => ({ ...item, isExiting: true }));
      return [
        ...visibleBubbles.map((bubble) => ({
          bubble,
          isExiting: false
        })),
        ...exitingBubbles
      ];
    });
  }, [visibleBubbleSignature]);

  useEffect(() => {
    if (!renderedBubbles.some((item) => item.isExiting)) {
      return;
    }

    const timeoutId = window.setTimeout(() => {
      setRenderedBubbles((current) => current.filter((item) => !item.isExiting));
    }, NOTIFICATION_EXIT_ANIMATION_MS);
    return () => window.clearTimeout(timeoutId);
  }, [renderedBubbles]);

  useEffect(() => {
    return () => {
      clearClearAllHoldTimer();
    };
  }, []);

  useEffect(() => {
    for (const bubble of overflowBubbles) {
      if (bubble.replyMode || bubble.replyDraft.length > 0) {
        notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
      }
    }
  }, [notificationStore, overflowBubbles]);

  useEffect(() => {
    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.defaultPrevented || event.ctrlKey || !event.metaKey) {
        return;
      }

      const key = shortcutKeyFromEvent(event);
      if (key === "\\" && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        toggleNotificationDock();
        return;
      }

      if ((key === "j" || key === "k") && !event.shiftKey && !event.altKey) {
        if (isEditableShortcutTarget(event.target)) {
          return;
        }
        const targetSourceChatId =
          activeSourceChatId && visibleSourceChatIds.includes(activeSourceChatId)
            ? activeSourceChatId
            : visibleSourceChatIds[0];
        if (!targetSourceChatId) {
          return;
        }
        event.preventDefault();
        scrollNotificationEntries(targetSourceChatId, key === "j" ? "down" : "up");
        return;
      }

      if (key === "-" && !event.shiftKey && !event.altKey) {
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

      if (event.shiftKey && event.altKey) {
        event.preventDefault();
        notificationStore.dismissCrossChatNotification(sourceChatId);
      } else if (event.shiftKey) {
        event.preventDefault();
        notificationStore.openCrossChatNotificationReply(sourceChatId);
      } else if (!event.altKey) {
        event.preventDefault();
        notificationStore.dismissCrossChatNotification(sourceChatId);
        navigate(`/chat/${sourceChatId}`);
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [activeSourceChatId, navigate, notificationStore, visibleSourceChatIds]);

  if (visibleBubbles.length === 0 && renderedBubbles.length === 0) {
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
      notificationStore.dismissCrossChatNotification(bubble.sourceChatId);
    } catch {
      chatStore.markMessageFailed(id);
      setReplyErrorsBySourceChatId((current) => ({
        ...current,
        [bubble.sourceChatId]: "Reply send failed."
      }));
    }
  }

  function clearClearAllHoldTimer() {
    if (clearAllHoldTimerRef.current !== null) {
      window.clearTimeout(clearAllHoldTimerRef.current);
      clearAllHoldTimerRef.current = null;
    }
  }

  function confirmClearAllNotifications() {
    clearClearAllHoldTimer();
    if (window.confirm("Clear all notifications?")) {
      notificationStore.clearCrossChatNotifications();
    }
  }

  function startClearAllHold() {
    clearClearAllHoldTimer();
    clearAllHoldTimerRef.current = window.setTimeout(() => {
      clearAllHoldTimerRef.current = null;
      confirmClearAllNotifications();
    }, CLEAR_ALL_HOLD_DELAY_MS);
  }

  function navigateToSourceChat(sourceChatId: string) {
    if (suppressNavigationClickRef.current) {
      suppressNavigationClickRef.current = false;
      return;
    }
    notificationStore.dismissCrossChatNotification(sourceChatId);
    navigate(`/chat/${sourceChatId}`);
  }

  function handleReplyButtonClick(bubble: CrossChatNotificationBubble) {
    if (bubble.replyMode) {
      notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
    } else {
      notificationStore.openCrossChatNotificationReply(bubble.sourceChatId);
    }
  }

  function dockNotifications() {
    setIsCollapsed(true);
  }

  function restoreNotifications() {
    setIsCollapsed(false);
  }

  function toggleNotificationDock() {
    setIsCollapsed((current) => !current);
  }

  function scrollNotificationEntries(sourceChatId: string, direction: "down" | "up") {
    const element = entriesRefsBySourceChatId.current[sourceChatId];
    if (!element || element.scrollHeight <= element.clientHeight) {
      return;
    }
    const lineIncrement = 56;
    const targetScrollTop =
      direction === "down"
        ? element.scrollTop + lineIncrement
        : element.scrollTop - lineIncrement;
    element.scrollTo({
      behavior: "smooth",
      top: Math.max(0, Math.min(targetScrollTop, element.scrollHeight - element.clientHeight))
    });
  }

  function handlePointerDown(event: PointerEvent<HTMLElement>) {
    dragStartXRef.current = event.clientX;
    dragStartYRef.current = event.clientY;
  }

  function handlePointerUp(event: PointerEvent<HTMLElement>) {
    const startX = dragStartXRef.current;
    const startY = dragStartYRef.current;
    dragStartXRef.current = null;
    dragStartYRef.current = null;
    if (startX === null || startY === null) {
      return;
    }

    const horizontal = event.clientX - startX;
    const vertical = event.clientY - startY;
    if (
      Math.abs(horizontal) <= Math.abs(vertical) ||
      Math.abs(horizontal) < COLLAPSE_SWIPE_THRESHOLD_PX
    ) {
      return;
    }

    suppressNavigationClickRef.current = true;
    window.setTimeout(() => {
      suppressNavigationClickRef.current = false;
    }, 0);
    if (horizontal > 0) {
      dockNotifications();
    } else if (isCollapsed) {
      restoreNotifications();
    }
  }

  return (
    <aside
      aria-label="Cross-chat notifications"
      className={
        isCollapsed
          ? "cross-chat-notification-overlay cross-chat-notification-overlay--collapsed"
          : "cross-chat-notification-overlay"
      }
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
    >
      {isCollapsed ? (
        <button
          aria-label="Show notifications"
          className="cross-chat-notification-peek"
          onClick={restoreNotifications}
          type="button"
        />
      ) : null}
      {renderedBubbles.map(({ bubble, isExiting }) => (
        <section
          aria-label={`${bubble.sourceTitle} notification`}
          className={
            isExiting
              ? "cross-chat-notification-bubble cross-chat-notification-bubble--exiting"
              : "cross-chat-notification-bubble"
          }
          data-testid="cross-chat-notification-bubble"
          key={bubble.sourceChatId}
          onBlur={(event) => {
            const nextFocused = event.relatedTarget;
            if (!(nextFocused instanceof Node) || !event.currentTarget.contains(nextFocused)) {
              setActiveSourceChatId((current) =>
                current === bubble.sourceChatId ? null : current
              );
            }
          }}
          onFocus={() => setActiveSourceChatId(bubble.sourceChatId)}
          onPointerEnter={() => setActiveSourceChatId(bubble.sourceChatId)}
          onPointerLeave={() =>
            setActiveSourceChatId((current) =>
              current === bubble.sourceChatId ? null : current
            )
          }
          tabIndex={0}
        >
          <header
            className="cross-chat-notification-header"
            onClick={() => navigateToSourceChat(bubble.sourceChatId)}
          >
            <div className="cross-chat-notification-title">
              <kbd>{Math.max(0, visibleSourceChatIds.indexOf(bubble.sourceChatId))}</kbd>
              <strong>{bubble.sourceTitle}</strong>
            </div>
            <div className="cross-chat-notification-actions">
              <button
                aria-label={bubble.replyMode ? "Close reply" : "Reply"}
                aria-pressed={bubble.replyMode}
                className={
                  bubble.replyMode
                    ? "cross-chat-notification-icon-button cross-chat-notification-icon-button--active"
                    : "cross-chat-notification-icon-button"
                }
                onClick={(event) => {
                  event.stopPropagation();
                  handleReplyButtonClick(bubble);
                }}
                type="button"
              >
                <Reply aria-hidden="true" size={15} strokeWidth={2.2} />
              </button>
              <button
                aria-label="Dismiss"
                className="cross-chat-notification-icon-button"
                onClick={(event) => {
                  event.stopPropagation();
                  notificationStore.dismissCrossChatNotification(bubble.sourceChatId)
                }}
                onPointerCancel={clearClearAllHoldTimer}
                onPointerDown={(event) => {
                  event.stopPropagation();
                  startClearAllHold();
                }}
                onPointerLeave={clearClearAllHoldTimer}
                onPointerUp={clearClearAllHoldTimer}
                type="button"
              >
                <X aria-hidden="true" size={16} strokeWidth={2.3} />
              </button>
            </div>
          </header>
          <div
            className="cross-chat-notification-entries"
            onClick={() => navigateToSourceChat(bubble.sourceChatId)}
            ref={(element) => {
              entriesRefsBySourceChatId.current[bubble.sourceChatId] = element;
            }}
          >
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

function getViewportHeight() {
  return typeof window === "undefined" ? 0 : window.innerHeight;
}

function visibleCapacityForViewportHeight(viewportHeight: number) {
  const availableHeight = Math.max(0, viewportHeight - OVERLAY_VERTICAL_MARGIN_PX * 2);
  const bubbleHeight = Math.min(
    NOTIFICATION_MAX_BUBBLE_HEIGHT_PX,
    viewportHeight * NOTIFICATION_MAX_BUBBLE_VIEWPORT_RATIO
  );
  const capacity = Math.floor(
    (availableHeight + NOTIFICATION_BUBBLE_GAP_PX) /
      (bubbleHeight + NOTIFICATION_BUBBLE_GAP_PX)
  );
  return Math.max(1, Math.min(VISIBLE_NOTIFICATION_LIMIT, capacity));
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

function isEditableShortcutTarget(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  if (target.isContentEditable) {
    return true;
  }

  return Boolean(
    target.closest("input, textarea, select, [contenteditable='true'], [role='textbox']")
  );
}
