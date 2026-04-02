import { useEffect, useRef, useState, type ReactNode } from "react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import type {
  ChatMessageRecord,
  SessionScrollState
} from "../../runtime/chat/chatDomainStore";
import { ExpandedMessageOverlay } from "./ExpandedMessageOverlay";
import { MessageAttachments } from "./MessageAttachments";
import { MessageLinkCards } from "./MessageLinkCards";
import { RichMessageBody, shouldOfferExpandedMessage } from "./RichMessageBody";
import { useVirtualMessageWindow } from "./useVirtualMessageWindow";

function getMessageSenderLabel(message: ChatMessageRecord) {
  return message.role === "user" ? "You" : message.sender ?? "Assistant";
}

function getMessageSenderInitial(message: ChatMessageRecord) {
  const label = getMessageSenderLabel(message).trim();
  const initial = Array.from(label).find((character) => /\p{Letter}|\p{Number}/u.test(character));
  return (initial ?? "?").toUpperCase();
}

export function MessageList({
  messages,
  onRememberScrollState,
  onUnreadAnchorConsumed,
  rememberedScrollState,
  sessionKey,
  unreadAnchorMessageId
}: {
  messages: ChatMessageRecord[];
  onRememberScrollState?: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onUnreadAnchorConsumed?: (messageId: string) => void;
  rememberedScrollState?: SessionScrollState;
  sessionKey?: string;
  unreadAnchorMessageId?: string | null;
}) {
  const { state: authState } = useAuthSessionStore();
  const [expandedMessageId, setExpandedMessageId] = useState<string | null>(null);
  const {
    containerRef,
    handleScroll,
    isAtBottom,
    registerMessageHeight,
    renderedMessages,
    scrollTop,
    scrollToBottom,
    scrollToMessage,
    scrollToOffset,
    totalHeight
  } = useVirtualMessageWindow(messages);
  const restoredSessionKeyRef = useRef<string | null>(null);
  const consumedUnreadAnchorRef = useRef<string | null>(null);
  const expandedMessage = messages.find((message) => message.id === expandedMessageId) ?? null;

  useEffect(() => {
    if (!sessionKey || !onRememberScrollState) {
      return;
    }

    if (restoredSessionKeyRef.current !== sessionKey) {
      return;
    }

    onRememberScrollState({
      offsetTop: scrollTop,
      sessionKey,
      stickToBottom: isAtBottom
    });
  }, [isAtBottom, onRememberScrollState, scrollTop, sessionKey]);

  useEffect(() => {
    if (!sessionKey) {
      return;
    }

    if (restoredSessionKeyRef.current === sessionKey) {
      return;
    }

    restoredSessionKeyRef.current = sessionKey;

    if (rememberedScrollState?.stickToBottom) {
      scrollToBottom();
      return;
    }

    if (rememberedScrollState) {
      scrollToOffset(rememberedScrollState.offsetTop);
      return;
    }

    scrollToOffset(0);
  }, [
    rememberedScrollState,
    scrollToBottom,
    scrollToOffset,
    sessionKey,
  ]);

  useEffect(() => {
    if (!sessionKey || !unreadAnchorMessageId) {
      return;
    }

    const unreadAnchorKey = `${sessionKey}:${unreadAnchorMessageId}`;

    if (consumedUnreadAnchorRef.current === unreadAnchorKey) {
      return;
    }

    if (!scrollToMessage(unreadAnchorMessageId, "center")) {
      return;
    }

    consumedUnreadAnchorRef.current = unreadAnchorKey;
    onUnreadAnchorConsumed?.(unreadAnchorMessageId);
  }, [onUnreadAnchorConsumed, scrollToMessage, sessionKey, unreadAnchorMessageId]);

  if (messages.length === 0) {
    return (
      <section className="message-list empty-state">
        <p className="eyebrow">No Messages Yet</p>
        <h2>This stream is ready for text chat.</h2>
        <p>Send the first message once the connection is live.</p>
      </section>
    );
  }

  return (
    <>
      <section
        aria-live="polite"
        className="message-list"
        data-testid="message-list"
        onScroll={handleScroll}
        ref={containerRef}
      >
        <div
          className="message-list-virtual-surface"
          style={{ height: `${Math.max(totalHeight, 0)}px` }}
        >
          {renderedMessages.map(({ message, offsetTop }) => (
            <MeasuredMessageRow
              key={message.id}
              messageId={message.id}
              offsetTop={offsetTop}
              onHeightChange={registerMessageHeight}
            >
              <MessageBubble
                message={message}
                onExpand={() => setExpandedMessageId(message.id)}
                serverUrl={authState.session?.serverUrl}
                token={authState.session?.token}
              />
            </MeasuredMessageRow>
          ))}
        </div>
      </section>
      {!isAtBottom ? (
        <div className="message-list-affordance-bar">
          <button
            className="button-secondary message-list-jump-button"
            data-testid="scroll-to-bottom-button"
            onClick={() => scrollToBottom()}
            type="button"
          >
            Jump to latest
          </button>
        </div>
      ) : null}
      {expandedMessage ? (
        <ExpandedMessageOverlay
          message={expandedMessage}
          onClose={() => setExpandedMessageId(null)}
        />
      ) : null}
    </>
  );
}

function MeasuredMessageRow({
  children,
  messageId,
  offsetTop,
  onHeightChange
}: {
  children: ReactNode;
  messageId: string;
  offsetTop: number;
  onHeightChange: (messageId: string, height: number) => void;
}) {
  const rowRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const row = rowRef.current;
    if (!row) {
      return;
    }

    function measure() {
      if (!rowRef.current) {
        return;
      }

      onHeightChange(messageId, rowRef.current.getBoundingClientRect().height);
    }

    measure();

    const resizeObserver =
      typeof window.ResizeObserver === "function"
        ? new window.ResizeObserver(() => {
            measure();
          })
        : null;

    resizeObserver?.observe(row);

    return () => {
      resizeObserver?.disconnect();
    };
  }, [messageId, onHeightChange]);

  return (
    <div
      className="message-list-row"
      ref={rowRef}
      style={{ top: `${offsetTop}px` }}
    >
      {children}
    </div>
  );
}

function MessageBubble({
  message,
  onExpand,
  serverUrl,
  token
}: {
  message: ChatMessageRecord;
  onExpand: () => void;
  serverUrl?: string;
  token?: string;
}) {
  const contentRef = useRef<HTMLDivElement | null>(null);
  const senderLabel = getMessageSenderLabel(message);
  const senderInitial = getMessageSenderInitial(message);
  const isUser = message.role === "user";

  return (
    <div
      className={
        isUser
          ? "message-cluster message-cluster--user"
          : "message-cluster message-cluster--assistant"
      }
    >
      {!isUser ? (
        <div
          aria-hidden="true"
          className="message-avatar message-avatar--assistant"
          data-testid={`message-avatar-${message.id}`}
        >
          {senderInitial}
        </div>
      ) : null}
      <article
        className={
          isUser
            ? "message-bubble message-bubble--user"
            : "message-bubble message-bubble--assistant"
        }
        data-testid={`message-${message.id}`}
      >
        <header className="message-meta">
          <span>{senderLabel}</span>
          <span>{new Date(message.timestamp).toLocaleTimeString()}</span>
        </header>
        <RichMessageBody content={message.content} contentRef={contentRef} />
        <MessageLinkCards content={message.content} contentRef={contentRef} />
        <MessageAttachments
          attachments={message.attachments}
          serverUrl={serverUrl}
          token={token}
        />
        {shouldOfferExpandedMessage(message.content) ? (
          <div className="message-actions">
            <button className="button-secondary" onClick={onExpand} type="button">
              Expand
            </button>
          </div>
        ) : null}
        <footer className="message-status">
          {message.delivery === "pending" ? "Sending..." : null}
          {message.delivery === "acked" ? "Accepted by provider" : null}
          {message.delivery === "failed" ? "Send failed" : null}
          {message.streaming ? "Streaming..." : null}
        </footer>
      </article>
      {isUser ? (
        <div
          aria-hidden="true"
          className="message-avatar message-avatar--user"
          data-testid={`message-avatar-${message.id}`}
        >
          {senderInitial}
        </div>
      ) : null}
    </div>
  );
}
