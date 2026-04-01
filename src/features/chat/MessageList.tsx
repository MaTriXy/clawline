import { useState } from "react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { ExpandedMessageOverlay } from "./ExpandedMessageOverlay";
import { MessageAttachments } from "./MessageAttachments";
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
          <article
            className={
              message.role === "user"
                ? "message-bubble message-bubble--user"
                : "message-bubble message-bubble--assistant"
            }
            data-testid={`message-${message.id}`}
            key={message.id}
          >
            <header className="message-meta">
              <span>{message.role === "user" ? "You" : message.sender ?? "Assistant"}</span>
              <span>{new Date(message.timestamp).toLocaleTimeString()}</span>
            </header>
            <RichMessageBody content={message.content} />
            <MessageAttachments
              attachments={message.attachments}
              serverUrl={authState.session?.serverUrl}
              token={authState.session?.token}
            />
            {shouldOfferExpandedMessage(message.content) ? (
              <div className="message-actions">
                <button
                  className="button-secondary"
                  onClick={() => setExpandedMessageId(message.id)}
                  type="button"
                >
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
