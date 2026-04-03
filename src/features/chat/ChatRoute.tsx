import { useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate, useParams } from "react-router-dom";
import { StreamManagerDrawer } from "../streams/StreamManagerDrawer";
import { getSessionProvisioningState } from "../streams/provisioning";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { ChatShell } from "./ChatShell";
import { useChatSessionCoordinator } from "./useChatSessionCoordinator";

export function ChatRoute() {
  const navigate = useNavigate();
  const params = useParams();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { state: transportState } = useTransportMachine();
  const [selectedUnreadAnchorMessageId, setSelectedUnreadAnchorMessageId] = useState<
    string | null
  >(null);
  const coordinator = useChatSessionCoordinator({
    provisionedSessionKeys: chatState.provisionedSessionKeys,
    routeSessionKey: params.sessionKey,
    streams: chatState.streams,
    transportPhase: transportState.phase
  });
  const selectedSessionKey = coordinator.engineActiveSessionKey;
  const uiSelectedSessionKey =
    coordinator.uiSelectedSessionKey ?? coordinator.engineActiveSessionKey;
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

  if (!authState.session?.token) {
    return <Navigate to="/pair" replace />;
  }

  if (!params.sessionKey && coordinator.firstProviderValidSessionKey) {
    return <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />;
  }

  if (
    coordinator.transition.bootRequestedSessionKey &&
    params.sessionKey === coordinator.transition.bootRequestedSessionKey &&
    transportState.phase === "live" &&
    chatState.provisionedSessionKeys.length > 0 &&
    !chatState.provisionedSessionKeys.includes(coordinator.transition.bootRequestedSessionKey)
  ) {
    return coordinator.firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
  }

  if (params.sessionKey && !activeStream) {
    return coordinator.firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
  }

  return (
    <>
      <ChatShell
        activeSessionKey={selectedSessionKey}
        isSessionListOpen={coordinator.isSessionListOpen}
        onCloseSessionList={coordinator.closeSessionList}
        onOpenSessionList={coordinator.openSessionList}
        onOpenStreamManager={coordinator.openStreamManager}
        onRememberScrollState={(input) => chatStore.rememberSessionScrollState(input)}
        provisioningState={provisioningState}
        onSelectSession={(sessionKey, source) => {
          coordinator.requestSessionSwitch(sessionKey, source);
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
        uiSelectedSessionKey={uiSelectedSessionKey}
        selectedUnreadAnchorMessageId={selectedUnreadAnchorMessageId}
        provisionedSessionKeys={chatState.provisionedSessionKeys}
        streams={chatState.streams}
        transportPhase={transportState.phase}
        unreadBySessionKey={chatState.unreadBySessionKey}
      />
      <StreamManagerDrawer
        activeSessionKey={uiSelectedSessionKey}
        isOpen={coordinator.isStreamManagerOpen}
        onClose={coordinator.closeStreamManager}
        onSelectSession={(sessionKey) => {
          if (sessionKey) {
            coordinator.requestSessionSwitch(sessionKey, "stream-manager");
          } else {
            coordinator.closeStreamManager();
          }
          navigate(sessionKey ? `/chat/${sessionKey}` : "/chat");
        }}
      />
    </>
  );
}
