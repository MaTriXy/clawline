import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { useChatSessionCoordinator } from "./useChatSessionCoordinator";

const STREAMS = [
  {
    sessionKey: "agent:main:clawline:user_1:main",
    displayName: "Personal",
    kind: "main" as const,
    orderIndex: 0,
    isBuiltIn: true,
    createdAt: 10,
    updatedAt: 10,
    adopted: false
  },
  {
    sessionKey: "agent:main:clawline:user_1:side",
    displayName: "Side Thread",
    kind: "custom" as const,
    orderIndex: 1,
    isBuiltIn: false,
    createdAt: 11,
    updatedAt: 11,
    adopted: false
  }
];

interface CoordinatorHookProps {
  routeSessionKey?: string;
  transportPhase: TransportPhase;
}

describe("useChatSessionCoordinator", () => {
  it("mirrors the current route-driven active session behavior", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: STREAMS.map((stream) => stream.sessionKey),
        routeSessionKey: "agent:main:clawline:user_1:side",
        streams: STREAMS,
        transportPhase: "live"
      })
    );

    await waitFor(() => {
      expect(result.current.uiSelectedSessionKey).toBe("agent:main:clawline:user_1:side");
    });

    expect(result.current.engineActiveSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.firstProviderValidSessionKey).toBe("agent:main:clawline:user_1:main");
    expect(result.current.transition.bootRequestedSessionKey).toBeNull();
  });

  it("falls back to the first provider-valid session when no route selection exists", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: ["agent:main:clawline:user_1:main"],
        routeSessionKey: undefined,
        streams: STREAMS,
        transportPhase: "replaying"
      })
    );

    await waitFor(() => {
      expect(result.current.uiSelectedSessionKey).toBe("agent:main:clawline:user_1:main");
    });

    expect(result.current.engineActiveSessionKey).toBe("agent:main:clawline:user_1:main");
    expect(result.current.transition.bootRequestedSessionKey).toBeNull();
  });

  it("tracks pending chat-switch metadata while keeping the current engine-active session", async () => {
    const { result, rerender } = renderHook(
      ({ routeSessionKey, transportPhase }: CoordinatorHookProps) =>
        useChatSessionCoordinator({
          provisionedSessionKeys: STREAMS.map((stream) => stream.sessionKey),
          routeSessionKey,
          streams: STREAMS,
          transportPhase
        }),
      {
        initialProps: {
          routeSessionKey: "agent:main:clawline:user_1:main",
          transportPhase: "replaying"
        } satisfies CoordinatorHookProps
      }
    );

    act(() => {
      result.current.openSessionList();
      result.current.openStreamManager();
      result.current.requestSessionSwitch("agent:main:clawline:user_1:side", "popup");
    });

    expect(result.current.isSessionListOpen).toBe(false);
    expect(result.current.isStreamManagerOpen).toBe(false);
    expect(result.current.uiSelectedSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.engineActiveSessionKey).toBe("agent:main:clawline:user_1:main");
    expect(result.current.transition.pendingSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.transition.source).toBe("popup");

    const rerenderCoordinator = rerender as (props: CoordinatorHookProps) => void;

    rerenderCoordinator({
      routeSessionKey: "agent:main:clawline:user_1:side",
      transportPhase: "live"
    });

    await waitFor(() => {
      expect(result.current.transition.pendingSessionKey).toBeNull();
    });

    expect(result.current.engineActiveSessionKey).toBe("agent:main:clawline:user_1:side");
  });
});
