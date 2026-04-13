import { describe, expect, it } from "vitest";
import {
  decodeTerminalSessionDescriptor,
  isTerminalAttachment,
  terminalDestinationLabel,
  TERMINAL_ATTACHMENT_MIME
} from "./terminal-wire";

describe("terminal-wire", () => {
  it("decodes version 2 terminal descriptors and preserves destination truth", () => {
    const descriptor = decodeTerminalSessionDescriptor({
      type: "document",
      mimeType: TERMINAL_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 2,
          terminalSessionId: "term_123",
          title: "eezo",
          destination: {
            address: "mike@eezo"
          },
          capabilities: {
            interactive: true,
            supportsBinaryFrames: true,
            supportsResize: true,
            supportsDetach: true
          }
        })
      )
    });

    expect(descriptor).toMatchObject({
      version: 2,
      terminalSessionId: "term_123",
      title: "eezo",
      destination: {
        address: "mike@eezo"
      }
    });
    expect(descriptor && terminalDestinationLabel(descriptor)).toBe("mike@eezo");
  });

  it("treats version 1 descriptors as destination-unknown", () => {
    const descriptor = decodeTerminalSessionDescriptor({
      type: "document",
      mimeType: TERMINAL_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          terminalSessionId: "term_legacy",
          title: "Legacy"
        })
      )
    });

    expect(descriptor).not.toBeNull();
    expect(descriptor && terminalDestinationLabel(descriptor)).toBe("Destination unknown");
  });

  it("ignores invalid or non-terminal attachments", () => {
    expect(
      isTerminalAttachment({
        type: "document",
        mimeType: "application/json"
      })
    ).toBe(false);
    expect(
      decodeTerminalSessionDescriptor({
        type: "document",
        mimeType: TERMINAL_ATTACHMENT_MIME,
        data: btoa(JSON.stringify({ version: 2 }))
      })
    ).toBeNull();
  });
});
