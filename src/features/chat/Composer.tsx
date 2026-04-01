import { useState } from "react";
import type { SessionProvisioningState } from "../streams/provisioning";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";

export function Composer({
  provisioningState,
  sessionKey
}: {
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
}) {
  const { state: authState } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [draft, setDraft] = useState("");

  const canSend =
    Boolean(sessionKey) &&
    transportState.phase === "live" &&
    provisioningState === "ready" &&
    draft.trim().length > 0;

  async function submit() {
    if (!sessionKey || !authState.session) {
      return;
    }

    const content = draft.trim();
    if (content.length === 0) {
      return;
    }

    const id = `c_${generateUuidV4()}`;
    const timestamp = Date.now();

    chatStore.enqueueOptimisticMessage({
      content,
      deviceId: authState.session.deviceId,
      id,
      sessionKey,
      timestamp
    });

    setDraft("");

    try {
      await transportStore.sendMessage({
        content,
        id,
        sessionKey
      });
    } catch {
      chatStore.markMessageFailed(id);
    }
  }

  return (
    <section className="composer-shell">
      <label className="sr-only" htmlFor="composer-input">
        Message
      </label>
      <textarea
        id="composer-input"
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            void submit();
          }
        }}
        placeholder={
          sessionKey
            ? transportState.phase === "live" && provisioningState === "ready"
              ? "Send a plain text message"
              : provisioningState === "unavailable"
                ? "This stream is unavailable for sending"
                : provisioningState === "waiting"
                  ? "Waiting for provisioning"
                  : "Waiting for connection"
            : "Select a session"
        }
        rows={3}
        value={draft}
      />
      <div className="composer-footer">
        <p className="connection-status">
          {transportState.phase === "live"
            ? "Connected"
            : transportState.phase === "recovering"
              ? "Reconnecting"
              : transportState.phase === "connecting" ||
                  transportState.phase === "authenticating" ||
                  transportState.phase === "replaying"
                ? "Connecting"
                : "Disconnected"}
        </p>
        <button
          className="button-primary"
          disabled={!canSend}
          onClick={() => {
            void submit();
          }}
          type="button"
        >
          Send
        </button>
      </div>
    </section>
  );
}
