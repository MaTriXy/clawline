import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { getSessionProvisioningState } from "../streams/provisioning";

export function StreamRail({
  activeSessionKey,
  onOpenStreamManager,
  onSelectSession,
  provisionedSessionKeys,
  streams,
  transportPhase,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  onOpenStreamManager: () => void;
  onSelectSession: (sessionKey: string) => void;
  provisionedSessionKeys: string[];
  streams: StreamRecord[];
  transportPhase: TransportPhase;
  unreadBySessionKey: Record<string, number>;
}) {
  return (
    <nav aria-label="Sessions" className="stream-rail" data-testid="stream-rail">
      <div className="stream-rail-header">
        <div>
          <p className="eyebrow">Sessions</p>
          <h2>Conversation structure</h2>
        </div>
        <button className="button-secondary" onClick={onOpenStreamManager} type="button">
          Manage
        </button>
      </div>
      <div className="stream-rail-list" data-testid="stream-rail-list">
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
                    ? "stream-chip active"
                    : "stream-chip"
                }
                key={stream.sessionKey}
                onClick={() => onSelectSession(stream.sessionKey)}
                type="button"
              >
                <span className="stream-chip-row">
                  <span>{stream.displayName}</span>
                  <span className="stream-chip-meta">
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
    </nav>
  );
}
