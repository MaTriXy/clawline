import { useEffect, useRef, useState, type CSSProperties, type TouchEvent } from "react";
import type {
  ChatMessageRecord,
  SessionScrollState,
  StreamRecord
} from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { Composer } from "./Composer";
import { MessageList } from "./MessageList";
import { SessionListSheet } from "./SessionListSheet";
import { StreamPageDots } from "./StreamPageDots";
import type { SessionProvisioningState } from "../streams/provisioning";
import { computeKeyboardInset } from "./visualViewportInset";

export function ChatShell({
  activeSessionKey,
  isSessionListOpen,
  onCloseSessionList,
  onOpenSessionList,
  onOpenStreamManager,
  onRememberScrollState,
  onSelectSession,
  onUnreadAnchorConsumed,
  provisionedSessionKeys,
  provisioningState,
  rememberedScrollState,
  selectedMessages,
  selectedSessionKey,
  selectedUnreadAnchorMessageId,
  streams,
  transportPhase,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  isSessionListOpen: boolean;
  onCloseSessionList: () => void;
  onOpenSessionList: () => void;
  onOpenStreamManager: () => void;
  onRememberScrollState: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onSelectSession: (sessionKey: string) => void;
  onUnreadAnchorConsumed: (messageId: string) => void;
  provisionedSessionKeys: string[];
  provisioningState: SessionProvisioningState;
  rememberedScrollState?: SessionScrollState;
  selectedMessages: ChatMessageRecord[];
  selectedSessionKey?: string;
  selectedUnreadAnchorMessageId?: string | null;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
  unreadBySessionKey: Record<string, number>;
}) {
  const [keyboardInset, setKeyboardInset] = useState(0);
  const touchStartRef = useRef<{
    active: boolean;
    x: number;
    y: number;
  }>({
    active: false,
    x: 0,
    y: 0
  });
  const baseViewportHeightRef = useRef(0);
  const unreadSessionKeys = new Set(
    Object.entries(unreadBySessionKey)
      .filter(([, unreadCount]) => unreadCount > 0)
      .map(([sessionKey]) => sessionKey)
  );
  const orderedSessionKeys = streams.map((stream) => stream.sessionKey);
  const shouldEnableSwipeNavigation = keyboardInset <= 0;

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    function syncKeyboardInset() {
      const visualViewport = window.visualViewport;
      const viewportHeight = visualViewport?.height ?? window.innerHeight;
      const viewportOffsetTop = visualViewport?.offsetTop ?? 0;
      const baseViewportHeight = visualViewport
        ? viewportHeight + viewportOffsetTop
        : window.innerHeight;

      baseViewportHeightRef.current = Math.max(
        baseViewportHeightRef.current,
        baseViewportHeight
      );

      const activeElement = document.activeElement;
      const isComposerFocused =
        activeElement instanceof HTMLTextAreaElement &&
        activeElement.id === "composer-input";

      setKeyboardInset(
        computeKeyboardInset({
          baseViewportHeight: baseViewportHeightRef.current || baseViewportHeight,
          isComposerFocused,
          viewportHeight,
          viewportOffsetTop
        })
      );
    }

    syncKeyboardInset();

    const visualViewport = window.visualViewport;
    visualViewport?.addEventListener("resize", syncKeyboardInset);
    visualViewport?.addEventListener("scroll", syncKeyboardInset);
    window.addEventListener("focusin", syncKeyboardInset);
    window.addEventListener("focusout", syncKeyboardInset);
    window.addEventListener("resize", syncKeyboardInset);

    return () => {
      visualViewport?.removeEventListener("resize", syncKeyboardInset);
      visualViewport?.removeEventListener("scroll", syncKeyboardInset);
      window.removeEventListener("focusin", syncKeyboardInset);
      window.removeEventListener("focusout", syncKeyboardInset);
      window.removeEventListener("resize", syncKeyboardInset);
    };
  }, []);

  const layoutStyle = {
    "--chat-keyboard-inset": `${keyboardInset}px`
  } as CSSProperties;

  function handleTouchEnd(event: TouchEvent<HTMLElement>) {
    if (!touchStartRef.current.active || orderedSessionKeys.length < 2) {
      return;
    }

    touchStartRef.current.active = false;
    const touch = event.changedTouches[0];

    if (!touch) {
      return;
    }

    const deltaX = touch.clientX - touchStartRef.current.x;
    const deltaY = touch.clientY - touchStartRef.current.y;

    if (Math.abs(deltaX) < 56 || Math.abs(deltaX) <= Math.abs(deltaY) * 1.25) {
      return;
    }

    const currentIndex = activeSessionKey
      ? orderedSessionKeys.indexOf(activeSessionKey)
      : -1;

    if (currentIndex < 0) {
      return;
    }

    const nextIndex = deltaX < 0 ? currentIndex + 1 : currentIndex - 1;
    const nextSessionKey = orderedSessionKeys[nextIndex];

    if (!nextSessionKey || nextSessionKey === activeSessionKey) {
      return;
    }

    onSelectSession(nextSessionKey);
  }

  function handleTouchStart(event: TouchEvent<HTMLElement>) {
    const target = event.target;

    if (
      !(target instanceof Element) ||
      target.closest(
        "button, input, textarea, select, a, label, audio, video, .chat-floating-stack"
      )
    ) {
      touchStartRef.current.active = false;
      return;
    }

    const touch = event.touches[0];

    if (!touch) {
      touchStartRef.current.active = false;
      return;
    }

    touchStartRef.current = {
      active: true,
      x: touch.clientX,
      y: touch.clientY
    };
  }

  return (
    <section
      className="chat-layout"
      data-testid="chat-layout"
      style={layoutStyle}
    >
      <main
        className="chat-panel"
        data-testid="chat-panel"
        onTouchCancel={shouldEnableSwipeNavigation ? () => {
          touchStartRef.current.active = false;
        } : undefined}
        onTouchEnd={shouldEnableSwipeNavigation ? handleTouchEnd : undefined}
        onTouchStart={shouldEnableSwipeNavigation ? handleTouchStart : undefined}
      >
        <MessageList
          messages={selectedMessages}
          onRememberScrollState={onRememberScrollState}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          viewportInsetBottom={keyboardInset}
          rememberedScrollState={rememberedScrollState}
          sessionKey={selectedSessionKey}
          unreadAnchorMessageId={selectedUnreadAnchorMessageId}
        />
        <div className="chat-floating-stack">
          {provisioningState === "waiting" ? (
            <div className="provisioning-banner provisioning-banner--floating">
              This session is waiting for provisioning before send becomes available.
            </div>
          ) : null}
          {provisioningState === "unavailable" ? (
            <div className="provisioning-banner provisioning-banner--warning provisioning-banner--floating">
              This session is unavailable for sending. Switch streams and try again.
            </div>
          ) : null}
          {streams.length > 0 ? (
            <div className="chat-dots-dock">
              <StreamPageDots
                activeSessionKey={activeSessionKey}
                onClick={onOpenSessionList}
                sessionKeys={streams.map((stream) => stream.sessionKey)}
                unreadSessionKeys={unreadSessionKeys}
              />
            </div>
          ) : null}
          <Composer
            activeStreamDisplayName={streams.find((s) => s.sessionKey === activeSessionKey)?.displayName}
            provisioningState={provisioningState}
            sessionKey={activeSessionKey}
          />
        </div>
      </main>
      <SessionListSheet
        activeSessionKey={activeSessionKey}
        isOpen={isSessionListOpen}
        onClose={onCloseSessionList}
        onOpenStreamManager={onOpenStreamManager}
        onSelectSession={onSelectSession}
        provisionedSessionKeys={provisionedSessionKeys}
        streams={streams}
        transportPhase={transportPhase}
        unreadBySessionKey={unreadBySessionKey}
      />
    </section>
  );
}
