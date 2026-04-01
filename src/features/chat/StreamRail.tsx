import type { StreamRecord } from "../../runtime/chat/chatDomainStore";

export function StreamRail({
  activeSessionKey,
  onSelectSession,
  streams,
  unreadBySessionKey
}: {
  activeSessionKey?: string;
  onSelectSession: (sessionKey: string) => void;
  streams: StreamRecord[];
  unreadBySessionKey: Record<string, number>;
}) {
  return (
    <nav aria-label="Sessions" className="stream-rail">
      <div className="stream-rail-header">
        <p className="eyebrow">Sessions</p>
        <h2>Provisioned streams</h2>
      </div>
      {streams.length === 0 ? (
        <p className="stream-empty">Waiting for provisioned sessions...</p>
      ) : (
        streams.map((stream) => (
          <button
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
              {typeof unreadBySessionKey[stream.sessionKey] === "number" &&
              unreadBySessionKey[stream.sessionKey] > 0 ? (
                <span
                  aria-label={`${unreadBySessionKey[stream.sessionKey]} unread messages`}
                  className="stream-unread-badge"
                >
                  {unreadBySessionKey[stream.sessionKey]}
                </span>
              ) : null}
            </span>
            <code>{stream.sessionKey}</code>
          </button>
        ))
      )}
    </nav>
  );
}
