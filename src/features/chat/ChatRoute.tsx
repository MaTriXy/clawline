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
  const [isSessionListOpen, setSessionListOpen] = useState(false);
  const [isStreamManagerOpen, setStreamManagerOpen] = useState(false);
  const [selectedUnreadAnchorMessageId, setSelectedUnreadAnchorMessageId] = useState<
    string | null
  >(null);
  const [bootRequestedSessionKey, setBootRequestedSessionKey] = useState(
    params.sessionKey ?? null
  );

  const firstProviderValidSessionKey =
    chatState.streams.find((stream) =>
      chatState.provisionedSessionKeys.includes(stream.sessionKey)
    )?.sessionKey ?? chatState.streams[0]?.sessionKey;

  const selectedSessionKey = params.sessionKey ?? firstProviderValidSessionKey;
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
    if (!selectedSessionKey) {
      return;
    }

    const unreadAnchor =
      chatState.firstUnreadMessageIdBySessionKey[selectedSessionKey] ?? null;

    setSelectedUnreadAnchorMessageId(unreadAnchor);

    if (!unreadAnchor) {
      chatStore.markSessionRead(selectedSessionKey);
    }
  }, [
    chatState.firstUnreadMessageIdBySessionKey,
    chatStore,
    selectedSessionKey
  ]);

  useEffect(() => {
    if (!bootRequestedSessionKey) {
      return;
    }

    if (params.sessionKey !== bootRequestedSessionKey) {
      setBootRequestedSessionKey(null);
      return;
    }

    if (
      transportState.phase === "live" &&
      chatState.provisionedSessionKeys.includes(bootRequestedSessionKey)
    ) {
      setBootRequestedSessionKey(null);
    }
  }, [
    bootRequestedSessionKey,
    chatState.provisionedSessionKeys,
    params.sessionKey,
    transportState.phase
  ]);

  if (!authState.session?.token) {
    return <Navigate to="/pair" replace />;
  }

  if (!params.sessionKey && firstProviderValidSessionKey) {
    return <Navigate replace to={`/chat/${firstProviderValidSessionKey}`} />;
  }

  if (
    bootRequestedSessionKey &&
    params.sessionKey === bootRequestedSessionKey &&
    transportState.phase === "live" &&
    chatState.provisionedSessionKeys.length > 0 &&
    !chatState.provisionedSessionKeys.includes(bootRequestedSessionKey)
  ) {
    return firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
  }

  if (params.sessionKey && !activeStream) {
    return firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
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
              : transportState.phase === "connecting" ||
                  transportState.phase === "authenticating" ||
                  transportState.phase === "replaying"
                ? "Connecting"
                : "Disconnected"
        }
        isSessionListOpen={isSessionListOpen}
        onCloseSessionList={() => setSessionListOpen(false)}
        onOpenSessionList={() => setSessionListOpen(true)}
        onOpenStreamManager={() => {
          setSessionListOpen(false);
          setStreamManagerOpen(true);
        }}
        onOpenSettings={() => setSettingsOpen(true)}
        onRememberScrollState={(input) => chatStore.rememberSessionScrollState(input)}
        provisioningState={provisioningState}
        onRetryConnection={() => transportStore.retryNow()}
        onSelectSession={(sessionKey) => {
          setSessionListOpen(false);
          navigate(`/chat/${sessionKey}`);
        }}
        onUnreadAnchorConsumed={(messageId) => {
          if (!selectedSessionKey || selectedUnreadAnchorMessageId !== messageId) {
            return;
          }

          chatStore.markSessionRead(selectedSessionKey);
          setSelectedUnreadAnchorMessageId(null);
        }}
        rememberedScrollState={
          selectedSessionKey
            ? chatState.scrollStateBySessionKey[selectedSessionKey]
            : undefined
        }
        selectedMessages={selectedMessages}
        selectedSessionKey={selectedSessionKey}
        selectedUnreadAnchorMessageId={selectedUnreadAnchorMessageId}
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
