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
  createBrowserCrossTabChannel,
  type CrossTabChannel,
  type CrossTabSendIntent,
  type MirroredTransportState
} from "./crossTabChannel";
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
  isBrowserOnline: boolean;
  ownership: "leader" | "follower";
  phase: TransportPhase;
  retryAttempt: number;
}

export interface SendMessageInput {
  content: string;
  id: string;
  sessionKey?: string;
  timestamp: number;
}

export interface TransportMachine {
  getState(): TransportState;
  subscribe(listener: () => void): () => void;
  retryNow(): void;
  sendMessage(input: SendMessageInput): Promise<void>;
}

interface CreateTransportMachineOptions {
  authSessionStore: AuthSessionStore;
  crossTabChannel?: CrossTabChannel;
  chatDomainStore: ChatDomainStore;
  browserRuntime?: BrowserRuntime;
  selectedSessionKeySource?: () => string | undefined;
  webSocketFactory?: WebSocketFactory;
}

interface BrowserRuntime {
  addEventListener(type: "offline" | "online", listener: () => void): () => void;
  clearTimeout(timeoutId: number): void;
  isOnline(): boolean;
  now(): number;
  setInterval(listener: () => void, delayMs: number): number;
  setTimeout(listener: () => void, delayMs: number): number;
  clearInterval(intervalId: number): void;
}

const TransportMachineContext = createContext<TransportMachine | null>(null);

const INITIAL_STATE: TransportState = {
  failureReason: null,
  isBrowserOnline: true,
  ownership: "follower",
  phase: "idle",
  retryAttempt: 0
};

const LEADER_ELECTION_DELAY_MS = 250;
const LEADER_HEARTBEAT_INTERVAL_MS = 1000;
const LEADER_STALE_AFTER_MS = 2500;

export function createTransportMachine({
  authSessionStore,
  crossTabChannel = createBrowserCrossTabChannel(),
  chatDomainStore,
  browserRuntime = createBrowserRuntime(),
  selectedSessionKeySource = createSelectedSessionKeySource(),
  webSocketFactory = createBrowserWebSocketFactory()
}: CreateTransportMachineOptions): TransportMachine {
  const baseStore = createStore<TransportState>({
    ...INITIAL_STATE,
    isBrowserOnline: browserRuntime.isOnline()
  });
  let socket: SocketLike | null = null;
  let reconnectTimer: number | null = null;
  let connectionGeneration = 0;
  let replayMessagesRemaining = 0;
  let leaderElectionTimer: number | null = null;
  let leaderHeartbeatInterval: number | null = null;
  let leaderMonitorInterval: number | null = null;
  let leaderPeerId: string | null = null;
  let lastLeaderHeartbeatAt = 0;
  let ownsTransport = false;

  chatDomainStore.subscribe(() => {
    if (!ownsTransport || !authSessionStore.getState().session) {
      return;
    }

    crossTabChannel.post({
      type: "chat_snapshot",
      peerId: crossTabChannel.peerId,
      snapshot: chatDomainStore.getState()
    });
  });

  baseStore.subscribe(() => {
    if (!ownsTransport || !authSessionStore.getState().session) {
      return;
    }

    broadcastTransportState();
  });

  crossTabChannel.subscribe((message) => {
    if (message.peerId === crossTabChannel.peerId) {
      return;
    }

    if (!authSessionStore.getState().session) {
      return;
    }

    switch (message.type) {
      case "hello":
      case "state_request":
        if (ownsTransport) {
          broadcastTransportState();
          crossTabChannel.post({
            type: "chat_snapshot",
            peerId: crossTabChannel.peerId,
            snapshot: chatDomainStore.getState()
          });
        }
        return;
      case "leader_heartbeat":
        acceptLeaderHeartbeat(message.peerId, message.state);
        return;
      case "chat_snapshot":
        if (ownsTransport) {
          return;
        }

        if (!shouldPreferLeader(message.peerId, leaderPeerId)) {
          return;
        }

        leaderPeerId = message.peerId;
        lastLeaderHeartbeatAt = browserRuntime.now();
        chatDomainStore.replaceSnapshot(message.snapshot);
        return;
      case "send_intent":
        if (ownsTransport) {
          void performSend(message.input);
        }
        return;
      default:
        return;
    }
  });

  browserRuntime.addEventListener("online", () => {
    baseStore.setState((current) => ({
      ...current,
      failureReason: current.phase === "recovering" ? null : current.failureReason,
      isBrowserOnline: true
    }));

    if (!authSessionStore.getState().session) {
      return;
    }

    if (ownsTransport) {
      if (baseStore.getState().phase !== "live") {
        void connect("retry");
      }
      return;
    }

    crossTabChannel.post({
      type: "state_request",
      peerId: crossTabChannel.peerId
    });
    scheduleLeaderElection();
  });
  browserRuntime.addEventListener("offline", () => {
    teardown(false);
    baseStore.setState((current) => ({
      ...current,
      failureReason: "Browser offline",
      isBrowserOnline: false,
      phase: authSessionStore.getState().session ? "recovering" : "idle"
    }));
  });

  leaderMonitorInterval = browserRuntime.setInterval(() => {
    if (ownsTransport || !authSessionStore.getState().session) {
      return;
    }

    if (
      leaderPeerId &&
      browserRuntime.now() - lastLeaderHeartbeatAt <= LEADER_STALE_AFTER_MS
    ) {
      return;
    }

    leaderPeerId = null;
    scheduleLeaderElection();
  }, 500);

  authSessionStore.subscribe(() => {
    const session = authSessionStore.getState().session;
    if (!session) {
      cancelLeaderElection();
      stopLeading(baseStore.getState().phase === "failed" ? "failed" : undefined);
      leaderPeerId = null;
      lastLeaderHeartbeatAt = 0;
      teardown(false);
      if (baseStore.getState().phase !== "failed") {
        baseStore.setState({
          ...INITIAL_STATE,
          isBrowserOnline: browserRuntime.isOnline()
        });
      }
      chatDomainStore.reset();
      return;
    }

    crossTabChannel.post({ type: "hello", peerId: crossTabChannel.peerId });
    crossTabChannel.post({ type: "state_request", peerId: crossTabChannel.peerId });
    scheduleLeaderElection();
  });

  if (authSessionStore.getState().session) {
    crossTabChannel.post({ type: "hello", peerId: crossTabChannel.peerId });
    crossTabChannel.post({ type: "state_request", peerId: crossTabChannel.peerId });
    scheduleLeaderElection();
  }

  async function connect(trigger: "auth-bootstrap" | "retry") {
    if (!ownsTransport) {
      return;
    }

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

    if (!browserRuntime.isOnline()) {
      baseStore.setState((current) => ({
        ...current,
        failureReason: "Browser offline",
        isBrowserOnline: false,
        phase: "recovering"
      }));
      return;
    }

    if (reconnectTimer != null) {
      browserRuntime.clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    teardown(false);

    connectionGeneration += 1;
    replayMessagesRemaining = 0;
    const generation = connectionGeneration;
    baseStore.setState((current) => ({
      ...current,
      failureReason: null,
      isBrowserOnline: true,
      ownership: "leader",
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
        ownership: "leader",
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
          replayMessagesRemaining = payload.replayCount ?? 0;
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
            isBrowserOnline: true,
            ownership: "leader",
            phase: "live",
            retryAttempt: trigger === "retry" ? baseStore.getState().retryAttempt : 0
          });
          return;
        }

        baseStore.setState({
          failureReason: payload.reason ?? "Authentication failed",
          isBrowserOnline: browserRuntime.isOnline(),
          ownership: "leader",
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
            {
              localDeviceId: authSessionStore.getState().session?.deviceId ?? "",
              message: payload,
              selectedSessionKey: selectedSessionKeySource(),
              source: replayMessagesRemaining > 0 ? "replay" : "live"
            }
          );
          if (replayMessagesRemaining > 0) {
            replayMessagesRemaining -= 1;
          }
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
      if (browserRuntime.isOnline() && ownsTransport) {
        scheduleReconnect(retryAttempt);
      }
      return {
        failureReason: reason,
        isBrowserOnline: browserRuntime.isOnline(),
        ownership: ownsTransport ? "leader" : "follower",
        phase: "recovering",
        retryAttempt
      };
    });
  }

  function scheduleReconnect(retryAttempt: number) {
    const delayMs = Math.min(1000 * 2 ** Math.max(retryAttempt - 1, 0), 8000);
    reconnectTimer = browserRuntime.setTimeout(() => {
      reconnectTimer = null;
      void connect("retry");
    }, delayMs);
  }

  function scheduleLeaderElection() {
    if (
      leaderElectionTimer != null ||
      ownsTransport ||
      !authSessionStore.getState().session
    ) {
      return;
    }

    leaderElectionTimer = browserRuntime.setTimeout(() => {
      leaderElectionTimer = null;

      if (
        ownsTransport ||
        !authSessionStore.getState().session ||
        (leaderPeerId &&
          browserRuntime.now() - lastLeaderHeartbeatAt <= LEADER_STALE_AFTER_MS)
      ) {
        return;
      }

      becomeLeader();
    }, LEADER_ELECTION_DELAY_MS);
  }

  function cancelLeaderElection() {
    if (leaderElectionTimer != null) {
      browserRuntime.clearTimeout(leaderElectionTimer);
      leaderElectionTimer = null;
    }
  }

  function acceptLeaderHeartbeat(
    peerId: string,
    state: MirroredTransportState
  ) {
    if (ownsTransport) {
      if (shouldPreferLeader(peerId, crossTabChannel.peerId)) {
        stopLeading();
      } else {
        return;
      }
    }

    leaderPeerId = peerId;
    lastLeaderHeartbeatAt = browserRuntime.now();
    cancelLeaderElection();

    baseStore.setState({
      ...state,
      ownership: "follower"
    });
  }

  function becomeLeader() {
    if (ownsTransport) {
      return;
    }

    ownsTransport = true;
    leaderPeerId = crossTabChannel.peerId;
    lastLeaderHeartbeatAt = browserRuntime.now();

    if (leaderHeartbeatInterval != null) {
      browserRuntime.clearInterval(leaderHeartbeatInterval);
    }
    leaderHeartbeatInterval = browserRuntime.setInterval(() => {
      broadcastTransportState();
    }, LEADER_HEARTBEAT_INTERVAL_MS);

    baseStore.setState((current) => ({
      ...current,
      ownership: "leader",
      phase: current.phase === "live" ? "recovering" : current.phase
    }));

    broadcastTransportState();
    crossTabChannel.post({
      type: "chat_snapshot",
      peerId: crossTabChannel.peerId,
      snapshot: chatDomainStore.getState()
    });
    void connect(baseStore.getState().phase === "idle" ? "auth-bootstrap" : "retry");
  }

  function stopLeading(nextPhase?: TransportPhase) {
    ownsTransport = false;
    if (leaderHeartbeatInterval != null) {
      browserRuntime.clearInterval(leaderHeartbeatInterval);
      leaderHeartbeatInterval = null;
    }

    teardown(false);
    baseStore.setState((current) => ({
      ...current,
      ownership: "follower",
      phase:
        nextPhase ??
        (authSessionStore.getState().session ? "recovering" : "idle")
    }));
    if (authSessionStore.getState().session) {
      crossTabChannel.post({ type: "state_request", peerId: crossTabChannel.peerId });
    }
  }

  function broadcastTransportState() {
    crossTabChannel.post({
      type: "leader_heartbeat",
      peerId: crossTabChannel.peerId,
      state: toMirroredTransportState(baseStore.getState())
    });
  }

  async function performSend(input: CrossTabSendIntent) {
    const session = authSessionStore.getState().session;
    if (!session) {
      throw new Error("Missing auth session");
    }

    if (baseStore.getState().phase !== "live" || !socket) {
      throw new Error("Transport is not live");
    }

    chatDomainStore.enqueueOptimisticMessage({
      content: input.content,
      deviceId: session.deviceId,
      id: input.id,
      sessionKey: input.sessionKey ?? selectedSessionKeySource() ?? "unassigned",
      timestamp: input.timestamp
    });

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
      if (ownsTransport) {
        void connect("retry");
        return;
      }

      crossTabChannel.post({ type: "state_request", peerId: crossTabChannel.peerId });
      scheduleLeaderElection();
    },
    async sendMessage(input) {
      if (ownsTransport) {
        await performSend(input);
        return;
      }

      if (baseStore.getState().phase !== "live" || leaderPeerId == null) {
        throw new Error("Transport is not live");
      }

      crossTabChannel.post({
        type: "send_intent",
        peerId: crossTabChannel.peerId,
        input
      });
    }
  };
}

function shouldPreferLeader(candidatePeerId: string, currentLeaderId: string | null) {
  return currentLeaderId == null || candidatePeerId.localeCompare(currentLeaderId) <= 0;
}

function toMirroredTransportState(state: TransportState): MirroredTransportState {
  return {
    failureReason: state.failureReason,
    isBrowserOnline: state.isBrowserOnline,
    phase: state.phase,
    retryAttempt: state.retryAttempt
  };
}

function createBrowserRuntime(): BrowserRuntime {
  return {
    addEventListener(type, listener) {
      window.addEventListener(type, listener);
      return () => window.removeEventListener(type, listener);
    },
    clearTimeout(timeoutId) {
      window.clearTimeout(timeoutId);
    },
    clearInterval(intervalId) {
      window.clearInterval(intervalId);
    },
    isOnline() {
      return navigator.onLine;
    },
    now() {
      return Date.now();
    },
    setInterval(listener, delayMs) {
      return window.setInterval(listener, delayMs);
    },
    setTimeout(listener, delayMs) {
      return window.setTimeout(listener, delayMs);
    }
  };
}

function createSelectedSessionKeySource() {
  return () => {
    const hashPath =
      window.location.hash.startsWith("#/") ?
        window.location.hash.slice(1)
      : window.location.pathname;
    const match = hashPath.match(/^\/chat\/(.+)$/);
    return match ? decodeURIComponent(match[1]) : undefined;
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
