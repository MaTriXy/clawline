import { useRef, useState } from "react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { ExpandedMessageOverlay } from "./ExpandedMessageOverlay";
import { MessageAttachments } from "./MessageAttachments";
import { MessageLinkCards } from "./MessageLinkCards";
import { RichMessageBody, shouldOfferExpandedMessage } from "./RichMessageBody";

export function MessageList({
  messages
}: {
  messages: ChatMessageRecord[];
}) {
  const { state: authState } = useAuthSessionStore();
  const [expandedMessageId, setExpandedMessageId] = useState<string | null>(null);

  if (messages.length === 0) {
    return (
      <section className="message-list empty-state">
        <p className="eyebrow">No Messages Yet</p>
        <h2>This stream is ready for text chat.</h2>
        <p>Send the first message once the connection is live.</p>
      </section>
    );
  }

  const expandedMessage = messages.find((message) => message.id === expandedMessageId) ?? null;

  return (
    <>
      <section aria-live="polite" className="message-list">
        {messages.map((message) => (
          <MessageBubble
            key={message.id}
            message={message}
            onExpand={() => setExpandedMessageId(message.id)}
            serverUrl={authState.session?.serverUrl}
            token={authState.session?.token}
          />
        ))}
      </section>
      {expandedMessage ? (
        <ExpandedMessageOverlay
          message={expandedMessage}
          onClose={() => setExpandedMessageId(null)}
        />
      ) : null}
    </>
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

  return (
    <article
      className={
        message.role === "user"
          ? "message-bubble message-bubble--user"
          : "message-bubble message-bubble--assistant"
      }
      data-testid={`message-${message.id}`}
    >
      <header className="message-meta">
        <span>{message.role === "user" ? "You" : message.sender ?? "Assistant"}</span>
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
  );
}
