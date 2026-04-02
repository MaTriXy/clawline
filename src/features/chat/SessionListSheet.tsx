import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { getSessionProvisioningState } from "../streams/provisioning";

export function SessionListSheet({
  activeSessionKey,
  connectionLabel,
  isOpen,
  onClose,
  onOpenSettings,
  onOpenStreamManager,
  onRetryConnection,
  onSelectSession,
  provisionedSessionKeys,
  streams,
  transportPhase,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  connectionLabel: string;
  isOpen: boolean;
  onClose: () => void;
  onOpenSettings: () => void;
  onOpenStreamManager: () => void;
  onRetryConnection: () => void;
  onSelectSession: (sessionKey: string) => void;
  provisionedSessionKeys: string[];
  streams: StreamRecord[];
  transportPhase: TransportPhase;
  unreadBySessionKey: Record<string, number>;
}) {
  if (!isOpen) {
    return null;
  }

  return (
    <div className="session-popover-backdrop" onClick={onClose}>
      <aside
        aria-label="Sessions"
        className="session-popover"
        data-testid="session-popover"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="session-popover-header">
          <div>
            <p className="eyebrow">Streams</p>
            <h2>Chats</h2>
            <p className="session-popover-copy">Swipe between conversations or pick one here.</p>
          </div>
        </div>
        <div className="session-popover-list" data-testid="session-popover-list">
          {streams.length === 0 ? (
            <p className="stream-empty">Waiting for provisioned sessions...</p>
          ) : (
            streams.map((stream) => {
              const provisioningState = getSessionProvisioningState({
                hasStream: true,
                provisionedSessionKeys,
                sessionKey: stream.sessionKey,
                transportPhase
              });

              return (
                <button
                  aria-current={stream.sessionKey === activeSessionKey ? "page" : undefined}
                  className={
                    stream.sessionKey === activeSessionKey
                      ? "session-sheet-card active"
                      : "session-sheet-card"
                  }
                  key={stream.sessionKey}
                  onClick={() => {
                    onSelectSession(stream.sessionKey);
                    onClose();
                  }}
                  type="button"
                >
                  <span className="session-sheet-card-row">
                    <span className="session-sheet-card-title">{stream.displayName}</span>
                    <span className="session-sheet-card-meta">
                      {typeof unreadBySessionKey[stream.sessionKey] === "number" &&
                      unreadBySessionKey[stream.sessionKey] > 0 ? (
                        <span
                          aria-label={`${unreadBySessionKey[stream.sessionKey]} unread messages`}
                          className="stream-unread-badge"
                        >
                          {unreadBySessionKey[stream.sessionKey]}
                        </span>
                      ) : null}
                      <span
                        className={`stream-status-pill stream-status-pill--${provisioningState}`}
                      >
                        {provisioningState}
                      </span>
                    </span>
                  </span>
                  <code>{stream.sessionKey}</code>
                </button>
              );
            })
          )}
        </div>
        <div className="session-popover-footer">
          <span className="status-pill session-popover-status">{connectionLabel}</span>
          <div className="session-popover-actions">
            <button
              className="button-secondary"
              onClick={() => {
                onClose();
                onRetryConnection();
              }}
              type="button"
            >
              Retry
            </button>
            <button
              className="button-secondary"
              onClick={() => {
                onClose();
                onOpenSettings();
              }}
              type="button"
            >
              Settings
            </button>
            <button
              className="button-secondary"
              onClick={() => {
                onClose();
                onOpenStreamManager();
              }}
              type="button"
            >
              Manage
            </button>
          </div>
        </div>
      </aside>
    </div>
  );
}
