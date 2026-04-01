import { useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate, useParams } from "react-router-dom";
import { SettingsDrawer } from "../settings/SettingsDrawer";
import { StreamManagerDrawer } from "../streams/StreamManagerDrawer";
import { getSessionProvisioningState } from "../streams/provisioning";
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
  const [isStreamManagerOpen, setStreamManagerOpen] = useState(false);

  const selectedSessionKey = params.sessionKey ?? chatState.streams[0]?.sessionKey;
  const activeStream = chatState.streams.find(
    (stream) => stream.sessionKey === selectedSessionKey
  );
  const provisioningState = getSessionProvisioningState({
    hasStream: Boolean(activeStream),
    provisionedSessionKeys: chatState.provisionedSessionKeys,
    sessionKey: selectedSessionKey,
    transportPhase: transportState.phase
  });

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

  if (params.sessionKey && !activeStream && chatState.streams.length > 0) {
    return <Navigate replace to={`/chat/${chatState.streams[0].sessionKey}`} />;
  }

  return (
    <>
      <ChatShell
        activeSessionKey={selectedSessionKey}
        activeStreamName={activeStream?.displayName}
        connectionLabel={
          transportState.phase === "live"
            ? "Connected"
            : transportState.phase === "recovering"
              ? "Reconnecting"
              : transportState.phase === "connecting" ||
                  transportState.phase === "authenticating" ||
                  transportState.phase === "replaying"
                ? "Connecting"
                : "Disconnected"
        }
        onOpenStreamManager={() => setStreamManagerOpen(true)}
        onOpenSettings={() => setSettingsOpen(true)}
        provisioningState={provisioningState}
        onRetryConnection={() => transportStore.retryNow()}
        onSelectSession={(sessionKey) => navigate(`/chat/${sessionKey}`)}
        selectedMessages={selectedMessages}
        provisionedSessionKeys={chatState.provisionedSessionKeys}
        streams={chatState.streams}
        transportPhase={transportState.phase}
        unreadBySessionKey={chatState.unreadBySessionKey}
      />
      <SettingsDrawer
        isOpen={isSettingsOpen}
        onClose={() => setSettingsOpen(false)}
      />
      <StreamManagerDrawer
        activeSessionKey={selectedSessionKey}
        isOpen={isStreamManagerOpen}
        onClose={() => setStreamManagerOpen(false)}
        onSelectSession={(sessionKey) => {
          setStreamManagerOpen(false);
          navigate(sessionKey ? `/chat/${sessionKey}` : "/chat");
        }}
      />
    </>
  );
}
