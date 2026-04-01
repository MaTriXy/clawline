import type { CrossTabChannel, CrossTabMessage } from "../../runtime/transport/crossTabChannel";

export class FakeCrossTabHub {
  private readonly subscribers = new Map<
    string,
    Set<(message: CrossTabMessage) => void>
  >();

  createChannel(peerId: string): CrossTabChannel {
    return {
      close: () => {
        this.subscribers.delete(peerId);
      },
      peerId,
      post: (message) => {
        for (const [targetPeerId, listeners] of this.subscribers) {
          if (targetPeerId === peerId) {
            continue;
          }

          for (const listener of listeners) {
            listener(message);
          }
        }
      },
      subscribe: (listener) => {
        const listeners = this.subscribers.get(peerId) ?? new Set();
        listeners.add(listener);
        this.subscribers.set(peerId, listeners);
        return () => {
          listeners.delete(listener);
        };
      }
    };
  }
}
