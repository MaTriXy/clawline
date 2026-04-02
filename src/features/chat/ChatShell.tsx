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

export function ChatShell({
  activeSessionKey,
  connectionLabel,
  isSessionListOpen,
  onCloseSessionList,
  onOpenSessionList,
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
  connectionLabel: string;
  isSessionListOpen: boolean;
  onCloseSessionList: () => void;
  onOpenSessionList: () => void;
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
  const unreadSessionKeys = new Set(
    Object.entries(unreadBySessionKey)
      .filter(([, unreadCount]) => unreadCount > 0)
      .map(([sessionKey]) => sessionKey)
  );

  return (
    <section className="chat-layout" data-testid="chat-layout">
      <main className="chat-panel" data-testid="chat-panel">
        <MessageList
          messages={selectedMessages}
          onRememberScrollState={onRememberScrollState}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
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
            provisioningState={provisioningState}
            sessionKey={activeSessionKey}
          />
        </div>
      </main>
      <SessionListSheet
        activeSessionKey={activeSessionKey}
        connectionLabel={connectionLabel}
        isOpen={isSessionListOpen}
        onClose={onCloseSessionList}
        onOpenSettings={onOpenSettings}
        onOpenStreamManager={onOpenStreamManager}
        onRetryConnection={onRetryConnection}
        onSelectSession={onSelectSession}
        provisionedSessionKeys={provisionedSessionKeys}
        streams={streams}
        transportPhase={transportPhase}
        unreadBySessionKey={unreadBySessionKey}
      />
    </section>
  );
}
