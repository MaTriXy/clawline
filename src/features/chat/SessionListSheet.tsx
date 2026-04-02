import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { getSessionProvisioningState } from "../streams/provisioning";

export function SessionListSheet({
  activeSessionKey,
  isOpen,
  onClose,
  onOpenStreamManager,
  onSelectSession,
  provisionedSessionKeys,
  streams,
  transportPhase,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  isOpen: boolean;
  onClose: () => void;
  onOpenStreamManager: () => void;
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
    <div className="drawer-backdrop session-sheet-backdrop" onClick={onClose}>
      <aside
        aria-label="Sessions"
        aria-modal="true"
        className="session-sheet"
        data-testid="session-sheet"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="session-sheet-header">
          <div>
            <p className="eyebrow">Streams</p>
            <h2>Sessions</h2>
            <p className="session-sheet-copy">Pick a conversation or manage the list.</p>
          </div>
          <div className="session-sheet-header-actions">
            <button className="button-secondary" onClick={onOpenStreamManager} type="button">
              Manage
            </button>
            <button className="button-secondary" onClick={onClose} type="button">
              Close
            </button>
          </div>
        </div>
        <div className="session-sheet-list" data-testid="session-sheet-list">
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
                  onClick={() => onSelectSession(stream.sessionKey)}
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
      </aside>
    </div>
  );
}
