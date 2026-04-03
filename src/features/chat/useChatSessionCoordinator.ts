import { useEffect, useMemo, useState } from "react";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";

export type ChatSessionSwitchSource =
  | "boot"
  | "popup"
  | "route"
  | "stream-manager"
  | "swipe";

export interface ChatSessionTransition {
  bootRequestedSessionKey: string | null;
  pendingSessionKey: string | null;
  source: ChatSessionSwitchSource | null;
}

export interface ChatSessionCoordinator {
  closeSessionList: () => void;
  closeStreamManager: () => void;
  engineActiveSessionKey?: string;
  firstProviderValidSessionKey?: string;
  isSessionListOpen: boolean;
  isStreamManagerOpen: boolean;
  openSessionList: () => void;
  openStreamManager: () => void;
  routeSessionExists: boolean;
  requestSessionSwitch: (sessionKey: string, source: ChatSessionSwitchSource) => void;
  transition: ChatSessionTransition;
  uiSelectedSessionKey?: string;
}

export function useChatSessionCoordinator({
  routeSessionKey,
  streams,
  provisionedSessionKeys,
  transportPhase
}: {
  provisionedSessionKeys: string[];
  routeSessionKey?: string;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
}): ChatSessionCoordinator {
  const [isSessionListOpen, setSessionListOpen] = useState(false);
  const [isStreamManagerOpen, setStreamManagerOpen] = useState(false);
  const [uiSelectedSessionKey, setUiSelectedSessionKey] = useState<string | undefined>(
    routeSessionKey
  );
  const [transition, setTransition] = useState<ChatSessionTransition>({
    bootRequestedSessionKey: routeSessionKey ?? null,
    pendingSessionKey: null,
    source: routeSessionKey ? "boot" : null
  });

  const firstProviderValidSessionKey = useMemo(
    () =>
      streams.find((stream) => provisionedSessionKeys.includes(stream.sessionKey))
        ?.sessionKey ?? streams[0]?.sessionKey,
    [provisionedSessionKeys, streams]
  );

  const routeSessionExists = useMemo(
    () =>
      routeSessionKey
        ? streams.some((stream) => stream.sessionKey === routeSessionKey)
        : false,
    [routeSessionKey, streams]
  );

  const engineActiveSessionKey = routeSessionKey ?? firstProviderValidSessionKey;

  useEffect(() => {
    setUiSelectedSessionKey(routeSessionKey ?? firstProviderValidSessionKey);
  }, [firstProviderValidSessionKey, routeSessionKey]);

  useEffect(() => {
    if (!transition.pendingSessionKey) {
      return;
    }

    if (routeSessionKey !== transition.pendingSessionKey) {
      return;
    }

    setTransition((current) => ({
      ...current,
      pendingSessionKey: null
    }));
  }, [routeSessionKey, transition.pendingSessionKey]);

  useEffect(() => {
    const bootRequestedSessionKey = transition.bootRequestedSessionKey;

    if (!bootRequestedSessionKey) {
      return;
    }

    if (routeSessionKey !== bootRequestedSessionKey) {
      setTransition((current) => ({
        ...current,
        bootRequestedSessionKey: null
      }));
      return;
    }

    if (
      transportPhase === "live" &&
      provisionedSessionKeys.includes(bootRequestedSessionKey)
    ) {
      setTransition((current) => ({
        ...current,
        bootRequestedSessionKey: null
      }));
    }
  }, [provisionedSessionKeys, routeSessionKey, transition.bootRequestedSessionKey, transportPhase]);

  return {
    closeSessionList() {
      setSessionListOpen(false);
    },
    closeStreamManager() {
      setStreamManagerOpen(false);
    },
    engineActiveSessionKey,
    firstProviderValidSessionKey,
    isSessionListOpen,
    isStreamManagerOpen,
    openSessionList() {
      setSessionListOpen(true);
    },
    openStreamManager() {
      setSessionListOpen(false);
      setStreamManagerOpen(true);
    },
    requestSessionSwitch(sessionKey, source) {
      setUiSelectedSessionKey(sessionKey);
      setSessionListOpen(false);
      setStreamManagerOpen(false);
      setTransition((current) => ({
        ...current,
        pendingSessionKey: sessionKey,
        source
      }));
    },
    routeSessionExists,
    transition,
    uiSelectedSessionKey
  };
}
