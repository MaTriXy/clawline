import { describe, expect, it } from "vitest";
import {
  projectComposerSendState,
  projectFailedMessageRetryState
} from "./chatSendState";

describe("chatSendState", () => {
  it("projects send availability, connection state, and placeholder from one seam", () => {
    expect(
      projectComposerSendState({
        activeStreamDisplayName: "Personal",
        draft: "Hello",
        isSubmitting: false,
        provisioningState: "ready",
        sessionKey: "agent:main:clawline:flynn:main",
        stagedAttachmentCount: 0,
        transportPhase: "live"
      })
    ).toEqual({
      canAttach: true,
      canSend: true,
      connectionState: "live",
      placeholder: "Personal — agent:main:clawline:flynn:main",
      sendAriaLabel: "Send"
    });

    expect(
      projectComposerSendState({
        activeStreamDisplayName: "Personal",
        draft: "Hello",
        isSubmitting: false,
        provisioningState: "ready",
        sessionKey: "agent:main:clawline:flynn:main",
        stagedAttachmentCount: 0,
        transportPhase: "recovering"
      })
    ).toMatchObject({
      canAttach: true,
      canSend: false,
      connectionState: "reconnecting",
      placeholder: "Waiting for connection",
      sendAriaLabel: "Send unavailable while reconnecting"
    });
  });

  it("projects failed-send retry eligibility from one seam", () => {
    expect(
      projectFailedMessageRetryState({
        delivery: "failed",
        pendingMessage: {
          attachments: [],
          content: "Retry me",
          createdAt: 1,
          sessionKey: "agent:main:clawline:flynn:main",
          wireAttachments: []
        },
        transportPhase: "live"
      })
    ).toEqual({
      action: "resend",
      canRetry: true,
      shouldShowRetry: true
    });

    expect(
      projectFailedMessageRetryState({
        delivery: "failed",
        pendingMessage: {
          attachments: [],
          content: "Retry me",
          createdAt: 1,
          sessionKey: "agent:main:clawline:flynn:main",
          wireAttachments: []
        },
        transportPhase: "recovering"
      })
    ).toEqual({
      action: "reconnect",
      canRetry: true,
      shouldShowRetry: true
    });
  });
});
