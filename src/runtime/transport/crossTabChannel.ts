import type { ChatDomainSnapshot } from "../chat/chatDomainStore";
import { generateUuidV4 } from "../shared/uuid";

export type MirroredTransportPhase =
  | "idle"
  | "connecting"
  | "authenticating"
  | "live"
  | "recovering"
  | "failed";

export interface MirroredTransportState {
  failureReason: string | null;
  isBrowserOnline: boolean;
  phase: MirroredTransportPhase;
  retryAttempt: number;
}

export interface CrossTabSendIntent {
  content: string;
  id: string;
  sessionKey?: string;
  timestamp: number;
}

export type CrossTabMessage =
  | {
      type: "hello" | "state_request";
      peerId: string;
    }
  | {
      type: "leader_heartbeat";
      peerId: string;
      state: MirroredTransportState;
    }
  | {
      type: "chat_snapshot";
      peerId: string;
      snapshot: ChatDomainSnapshot;
    }
  | {
      type: "send_intent";
      peerId: string;
      input: CrossTabSendIntent;
    };

export interface CrossTabChannel {
  close(): void;
  peerId: string;
  post(message: CrossTabMessage): void;
  subscribe(listener: (message: CrossTabMessage) => void): () => void;
}

const DEFAULT_CHANNEL_NAME = "clawline-phase2-runtime";

export function createBrowserCrossTabChannel(
  channelName = DEFAULT_CHANNEL_NAME
): CrossTabChannel {
  const peerId = generateUuidV4();
  const channel = new BroadcastChannel(channelName);
  const listeners = new Set<(message: CrossTabMessage) => void>();

  channel.onmessage = (event: MessageEvent<CrossTabMessage>) => {
    const message = event.data;
    if (!message || typeof message !== "object") {
      return;
    }

    listeners.forEach((listener) => listener(message));
  };

  return {
    close() {
      listeners.clear();
      channel.close();
    },
    peerId,
    post(message) {
      channel.postMessage(message);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    }
  };
}
