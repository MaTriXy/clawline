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

type MessageSizeClass = "short" | "medium" | "long";

function getMessageSenderLabel(message: ChatMessageRecord) {
  return message.role === "user" ? "You" : message.sender ?? "Assistant";
}

function getMessageSenderInitial(message: ChatMessageRecord) {
  const label = getMessageSenderLabel(message).trim();
  const initial = Array.from(label).find((character) => /\p{Letter}|\p{Number}/u.test(character));
  return (initial ?? "?").toUpperCase();
}

function analyzeMessagePresentation(message: ChatMessageRecord) {
  const normalizedContent = message.content.trim();
  const wordCount = countWords(normalizedContent);
  const hasMarkdownTable = /\n\|(?:\s*:?-+:?\s*\|)+\s*(?:\n|$)/m.test(normalizedContent);
  const hasBlockContent =
    message.attachments.length > 0 ||
    hasMarkdownTable ||
    normalizedContent.includes("```") ||
    normalizedContent.includes("\n\n");
  const hasLinkPreviewCandidate = /https?:\/\/\S+|\[[^\]]+\]\((https?:\/\/[^)]+)\)/.test(
    normalizedContent
  );
  const sizeClass: MessageSizeClass = hasBlockContent
    ? "long"
    : wordCount <= 3
      ? "short"
      : wordCount <= 20
        ? "medium"
        : "long";

  return {
    isTruncated: shouldOfferExpandedMessage(message.content),
    isWide: message.attachments.length > 0 || hasMarkdownTable || hasLinkPreviewCandidate,
    sizeClass
  };
}

function countWords(content: string) {
  return content
    .replace(/```[\s\S]*?```/g, " code ")
    .replace(/\[[^\]]+\]\((https?:\/\/[^)]+)\)/g, " link ")
    .replace(/[|*_`>#-]/g, " ")
    .split(/\s+/)
    .filter(Boolean).length;
}

export function MessageList({
  messages,
  onRememberScrollState,
  onUnreadAnchorConsumed,
  rememberedScrollState,
  sessionKey,
  unreadAnchorMessageId,
  viewportInsetBottom = 0
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
  viewportInsetBottom?: number;
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

  useEffect(() => {
    if (viewportInsetBottom <= 0) {
      return;
    }

    const activeElement = document.activeElement;
    const isComposerFocused =
      activeElement instanceof HTMLTextAreaElement &&
      activeElement.id === "composer-input";

    if (!isComposerFocused && !isAtBottom) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      scrollToBottom();
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [isAtBottom, scrollToBottom, viewportInsetBottom]);

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
  const presentation = analyzeMessagePresentation(message);

  return (
    <article
      className={
        [
          "message-bubble",
          isUser ? "message-bubble--user" : "message-bubble--assistant",
          `message-bubble--${presentation.sizeClass}`,
          presentation.isWide ? "message-bubble--wide" : null,
          presentation.isTruncated ? "message-bubble--truncated" : null
        ]
          .filter(Boolean)
          .join(" ")
      }
      data-message-size={presentation.sizeClass}
      data-testid={`message-${message.id}`}
      onClick={presentation.isTruncated ? onExpand : undefined}
      role={presentation.isTruncated ? "button" : undefined}
      style={presentation.isTruncated ? { cursor: "pointer" } : undefined}
    >
      <header className="message-header">
        <div
          aria-hidden="true"
          className={isUser ? "message-avatar message-avatar--user" : "message-avatar message-avatar--assistant"}
          data-testid={`message-avatar-${message.id}`}
        >
          {senderInitial}
        </div>
        <div className="message-header-text">
          <span className="message-sender-name">{senderLabel}</span>
          <span className="message-timestamp">{new Date(message.timestamp).toLocaleTimeString()}</span>
        </div>
      </header>
      <RichMessageBody
        className={[
          `message-markdown--${presentation.sizeClass}`,
          presentation.isWide ? "message-markdown--wide" : null
        ]
          .filter(Boolean)
          .join(" ")}
        content={message.content}
        contentRef={contentRef}
      />
      <MessageLinkCards content={message.content} contentRef={contentRef} />
      <MessageAttachments
        attachments={message.attachments}
        serverUrl={serverUrl}
        token={token}
      />
      {/* Tap bubble to expand — no visible button, matches iOS behavior */}
      <footer className="message-status">
        {message.delivery === "pending" ? "Sending..." : null}
        {message.delivery === "acked" ? "Accepted by provider" : null}
        {message.delivery === "failed" ? "Send failed" : null}
        {message.streaming ? "Streaming..." : null}
      </footer>
    </article>
  );
}
