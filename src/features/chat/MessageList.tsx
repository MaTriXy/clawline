import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";

export function MessageList({
  messages
}: {
  messages: ChatMessageRecord[];
}) {
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
          <p>{message.content}</p>
          <footer className="message-status">
            {message.delivery === "pending" ? "Sending..." : null}
            {message.delivery === "acked" ? "Accepted by provider" : null}
            {message.delivery === "failed" ? "Send failed" : null}
            {message.streaming ? "Streaming..." : null}
          </footer>
        </article>
      ))}
    </section>
  );
}
