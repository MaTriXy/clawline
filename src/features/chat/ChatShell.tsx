import type { ChatMessageRecord, StreamRecord } from "../../runtime/chat/chatDomainStore";
import { Composer } from "./Composer";
import { MessageList } from "./MessageList";
import { StreamRail } from "./StreamRail";

export function ChatShell({
  activeSessionKey,
  connectionLabel,
  onOpenSettings,
  onRetryConnection,
  onSelectSession,
  selectedMessages,
  streams,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  connectionLabel: string;
  onOpenSettings: () => void;
  onRetryConnection: () => void;
  onSelectSession: (sessionKey: string) => void;
  selectedMessages: ChatMessageRecord[];
  streams: StreamRecord[];
  unreadBySessionKey: Record<string, number>;
}) {
  return (
    <section className="chat-layout">
      <StreamRail
        activeSessionKey={activeSessionKey}
        onSelectSession={onSelectSession}
        streams={streams}
        unreadBySessionKey={unreadBySessionKey}
      />
      <main className="chat-panel">
        <header className="chat-header">
          <div>
            <p className="eyebrow">Clawline</p>
            <h1>{activeSessionKey ?? "Waiting for a session"}</h1>
          </div>
          <div className="chat-header-actions">
            <span className="status-pill">{connectionLabel}</span>
            <button className="button-secondary" onClick={onRetryConnection} type="button">
              Retry
            </button>
            <button className="button-secondary" onClick={onOpenSettings} type="button">
              Settings
            </button>
          </div>
        </header>
        <MessageList messages={selectedMessages} />
        <Composer sessionKey={activeSessionKey} />
      </main>
    </section>
  );
}
