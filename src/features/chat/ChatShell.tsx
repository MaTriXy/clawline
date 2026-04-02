import type {
  ChatMessageRecord,
  SessionScrollState,
  StreamRecord
} from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { Composer } from "./Composer";
import { MessageList } from "./MessageList";
import { StreamRail } from "./StreamRail";
import type { SessionProvisioningState } from "../streams/provisioning";

export function ChatShell({
  activeSessionKey,
  activeStreamName,
  connectionLabel,
  onOpenStreamManager,
  onOpenSettings,
  onRememberScrollState,
  onRetryConnection,
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
  activeStreamName?: string;
  connectionLabel: string;
  onOpenStreamManager: () => void;
  onOpenSettings: () => void;
  onRememberScrollState: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onRetryConnection: () => void;
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
  return (
    <section className="chat-layout">
      <StreamRail
        activeSessionKey={activeSessionKey}
        onOpenStreamManager={onOpenStreamManager}
        onSelectSession={onSelectSession}
        provisionedSessionKeys={provisionedSessionKeys}
        streams={streams}
        transportPhase={transportPhase}
        unreadBySessionKey={unreadBySessionKey}
      />
      <main className="chat-panel">
        <header className="chat-header">
          <div>
            <p className="eyebrow">Clawline</p>
            <h1>{activeStreamName ?? activeSessionKey ?? "Waiting for a session"}</h1>
            {activeSessionKey ? <code>{activeSessionKey}</code> : null}
          </div>
          <div className="chat-header-actions">
            <span className="status-pill">{connectionLabel}</span>
            <button
              className="button-secondary"
              onClick={onOpenStreamManager}
              type="button"
            >
              Streams
            </button>
            <button className="button-secondary" onClick={onRetryConnection} type="button">
              Retry
            </button>
            <button className="button-secondary" onClick={onOpenSettings} type="button">
              Settings
            </button>
          </div>
        </header>
        {provisioningState === "waiting" ? (
          <div className="provisioning-banner">
            This session is waiting for provisioning before send becomes available.
          </div>
        ) : null}
        {provisioningState === "unavailable" ? (
          <div className="provisioning-banner provisioning-banner--warning">
            This session is unavailable for sending. Switch streams and try again.
          </div>
        ) : null}
        <MessageList
          messages={selectedMessages}
          onRememberScrollState={onRememberScrollState}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          rememberedScrollState={rememberedScrollState}
          sessionKey={selectedSessionKey}
          unreadAnchorMessageId={selectedUnreadAnchorMessageId}
        />
        <Composer
          provisioningState={provisioningState}
          sessionKey={activeSessionKey}
        />
      </main>
    </section>
  );
}
