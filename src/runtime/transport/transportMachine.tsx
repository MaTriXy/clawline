import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import {
  parseAuthResultPayload,
  parseServerPayload,
  serializeAuthPayload,
  serializeClientMessage
} from "../../protocol/chat-wire";
import type { AuthSessionStore } from "../auth/authSessionStore";
import type { ChatDomainStore } from "../chat/chatDomainStore";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import {
  createBrowserWebSocketFactory,
  type SocketLike,
  type WebSocketFactory
} from "./wsClient";

export type TransportPhase =
  | "idle"
  | "connecting"
  | "authenticating"
  | "live"
  | "recovering"
  | "failed";

export interface TransportState {
  failureReason: string | null;
  phase: TransportPhase;
  retryAttempt: number;
}

export interface SendMessageInput {
  content: string;
  id: string;
  sessionKey?: string;
}

export interface TransportMachine {
  getState(): TransportState;
  subscribe(listener: () => void): () => void;
  retryNow(): void;
  sendMessage(input: SendMessageInput): Promise<void>;
}

interface CreateTransportMachineOptions {
  authSessionStore: AuthSessionStore;
  chatDomainStore: ChatDomainStore;
  webSocketFactory?: WebSocketFactory;
}

const TransportMachineContext = createContext<TransportMachine | null>(null);

const INITIAL_STATE: TransportState = {
  failureReason: null,
  phase: "idle",
  retryAttempt: 0
};

export function createTransportMachine({
  authSessionStore,
  chatDomainStore,
  webSocketFactory = createBrowserWebSocketFactory()
}: CreateTransportMachineOptions): TransportMachine {
  const baseStore = createStore(INITIAL_STATE);
  let socket: SocketLike | null = null;
  let reconnectTimer: number | null = null;
  let connectionGeneration = 0;

  authSessionStore.subscribe(() => {
    const session = authSessionStore.getState().session;
    if (!session) {
      teardown(false);
      if (baseStore.getState().phase !== "failed") {
        baseStore.setState(INITIAL_STATE);
      }
      chatDomainStore.reset();
      return;
    }

    if (baseStore.getState().phase === "idle") {
      void connect("auth-bootstrap");
    }
  });

  if (authSessionStore.getState().session) {
    void connect("auth-bootstrap");
  }

  async function connect(trigger: "auth-bootstrap" | "retry") {
    const state = baseStore.getState();
    if (
      state.phase === "connecting" ||
      state.phase === "authenticating" ||
      state.phase === "live"
    ) {
      return;
    }

    const session = authSessionStore.getState().session;
    if (!session) {
      return;
    }

    if (reconnectTimer != null) {
      window.clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    teardown(false);

    connectionGeneration += 1;
    const generation = connectionGeneration;
    baseStore.setState((current) => ({
      ...current,
      failureReason: null,
      phase: "connecting"
    }));

    const nextSocket = webSocketFactory(session.serverUrl);
    socket = nextSocket;

    nextSocket.onopen = () => {
      if (generation !== connectionGeneration) {
        return;
      }

      baseStore.setState((current) => ({
        ...current,
        phase: "authenticating"
      }));

      nextSocket.send(
        serializeAuthPayload({
          type: "auth",
          protocolVersion: 1,
          token: session.token,
          deviceId: session.deviceId,
          lastMessageId: chatDomainStore.getState().lastServerEventId
        })
      );
    };

    nextSocket.onmessage = (event) => {
      if (generation !== connectionGeneration) {
        return;
      }

      const type = JSON.parse(event.data).type as string | undefined;
      if (type === "auth_result") {
        const payload = parseAuthResultPayload(event.data);
        if (payload.success) {
          if (typeof payload.isAdmin === "boolean") {
            authSessionStore.updateAdminStatus(payload.isAdmin);
          }

          chatDomainStore.applySessionInfo({
            type: "session_info",
            userId: payload.userId,
            isAdmin: payload.isAdmin,
            sessionKeys: payload.sessionKeys,
            sessions: payload.sessions
          });

          baseStore.setState({
            failureReason: null,
            phase: "live",
            retryAttempt: trigger === "retry" ? baseStore.getState().retryAttempt : 0
          });
          return;
        }

        baseStore.setState({
          failureReason: payload.reason ?? "Authentication failed",
          phase: "failed",
          retryAttempt: baseStore.getState().retryAttempt
        });
        teardown(false);
        authSessionStore.logout();
        return;
      }

      const payload = parseServerPayload(event.data);
      switch (payload.type) {
        case "message":
          chatDomainStore.applyIncomingMessage(
            payload,
            authSessionStore.getState().session?.deviceId ?? ""
          );
          return;
        case "ack":
          chatDomainStore.markMessageAcked(payload.id);
          return;
        case "stream_snapshot":
          chatDomainStore.applyStreamSnapshot(payload.streams);
          return;
        case "session_info":
          chatDomainStore.applySessionInfo(payload);
          return;
        case "error":
          if (payload.messageId) {
            chatDomainStore.markMessageFailed(payload.messageId);
          }
          baseStore.setState((current) => ({
            ...current,
            failureReason: payload.message ?? payload.code
          }));
          return;
        default:
          return;
      }
    };

    nextSocket.onerror = () => {
      if (generation !== connectionGeneration) {
        return;
      }
      enterRecovery("Connection error");
    };

    nextSocket.onclose = () => {
      if (generation !== connectionGeneration) {
        return;
      }

      const currentPhase = baseStore.getState().phase;
      if (currentPhase === "idle" || currentPhase === "failed") {
        return;
      }

      enterRecovery("Connection closed");
    };
  }

  function enterRecovery(reason: string) {
    teardown(false);

    baseStore.setState((current) => {
      const retryAttempt = current.retryAttempt + 1;
      scheduleReconnect(retryAttempt);
      return {
        failureReason: reason,
        phase: "recovering",
        retryAttempt
      };
    });
  }

  function scheduleReconnect(retryAttempt: number) {
    const delayMs = Math.min(1000 * 2 ** Math.max(retryAttempt - 1, 0), 8000);
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      void connect("retry");
    }, delayMs);
  }

  function teardown(incrementGeneration: boolean) {
    if (incrementGeneration) {
      connectionGeneration += 1;
    }

    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
      socket = null;
    }
  }

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    retryNow() {
      void connect("retry");
    },
    async sendMessage(input) {
      if (baseStore.getState().phase !== "live" || !socket) {
        throw new Error("Transport is not live");
      }

      socket.send(
        serializeClientMessage({
          type: "message",
          id: input.id,
          content: input.content,
          attachments: [],
          sessionKey: input.sessionKey
        })
      );
    }
  };
}

export function TransportMachineProvider({
  children,
  value
}: {
  children: ReactNode;
  value: TransportMachine;
}) {
  return (
    <TransportMachineContext.Provider value={value}>
      {children}
    </TransportMachineContext.Provider>
  );
}

export function useTransportMachine() {
  const store = useContext(TransportMachineContext);
  if (!store) {
    throw new Error("TransportMachineProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}
