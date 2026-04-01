import { useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate, useParams } from "react-router-dom";
import { SettingsDrawer } from "../settings/SettingsDrawer";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { ChatShell } from "./ChatShell";

export function ChatRoute() {
  const navigate = useNavigate();
  const params = useParams();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [isSettingsOpen, setSettingsOpen] = useState(false);

  const selectedSessionKey = params.sessionKey ?? chatState.streams[0]?.sessionKey;

  const selectedMessages = useMemo(
    () =>
      selectedSessionKey
        ? chatState.messagesBySessionKey[selectedSessionKey] ?? []
        : [],
    [chatState.messagesBySessionKey, selectedSessionKey]
  );

  useEffect(() => {
    chatStore.markSessionRead(selectedSessionKey);
  }, [chatStore, selectedSessionKey]);

  if (!authState.session?.token) {
    return <Navigate to="/pair" replace />;
  }

  if (!params.sessionKey && chatState.streams.length > 0) {
    return <Navigate replace to={`/chat/${chatState.streams[0].sessionKey}`} />;
  }

  return (
    <>
      <ChatShell
        activeSessionKey={selectedSessionKey}
        connectionLabel={
          transportState.phase === "live"
            ? "Connected"
            : transportState.phase === "recovering"
              ? "Reconnecting"
              : "Disconnected"
        }
        onOpenSettings={() => setSettingsOpen(true)}
        onRetryConnection={() => transportStore.retryNow()}
        onSelectSession={(sessionKey) => navigate(`/chat/${sessionKey}`)}
        selectedMessages={selectedMessages}
        streams={chatState.streams}
        unreadBySessionKey={chatState.unreadBySessionKey}
      />
      <SettingsDrawer
        isOpen={isSettingsOpen}
        onClose={() => setSettingsOpen(false)}
      />
    </>
  );
}
