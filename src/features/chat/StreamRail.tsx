import type { StreamRecord } from "../../runtime/chat/chatDomainStore";

export function StreamRail({
  activeSessionKey,
  onSelectSession,
  streams
}: {
  activeSessionKey?: string;
  onSelectSession: (sessionKey: string) => void;
  streams: StreamRecord[];
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
            <span>{stream.displayName}</span>
            <code>{stream.sessionKey}</code>
          </button>
        ))
      )}
    </nav>
  );
}
