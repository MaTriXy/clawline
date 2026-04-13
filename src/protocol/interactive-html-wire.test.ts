import { describe, expect, it } from "vitest";
import {
  decodeInteractiveHtmlDescriptor,
  interactiveHtmlTitle,
  INTERACTIVE_HTML_ATTACHMENT_MIME,
  isInteractiveHtmlAttachment
} from "./interactive-html-wire";

describe("interactive-html-wire", () => {
  it("decodes version 1 descriptors with fixed heights and metadata", () => {
    const descriptor = decodeInteractiveHtmlDescriptor({
      type: "document",
      mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          html: "<body><p>Hello</p></body>",
          metadata: {
            title: " Demo ",
            height: 320,
            maxHeight: 420,
            backgroundColor: "#123456"
          }
        })
      )
    });

    expect(descriptor).toEqual({
      version: 1,
      html: "<body><p>Hello</p></body>",
      metadata: {
        title: " Demo ",
        height: { kind: "fixed", value: 320 },
        maxHeight: 420,
        backgroundColor: "#123456"
      }
    });
    expect(descriptor && interactiveHtmlTitle(descriptor)).toBe("Demo");
  });

  it("decodes auto-height descriptors", () => {
    const descriptor = decodeInteractiveHtmlDescriptor({
      type: "document",
      mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          html: "<body><p>Hello</p></body>",
          metadata: {
            height: "auto"
          }
        })
      )
    });

    expect(descriptor?.metadata?.height).toEqual({ kind: "auto" });
  });

  it("rejects invalid or non-interactive payloads", () => {
    expect(
      isInteractiveHtmlAttachment({
        type: "document",
        mimeType: "application/json"
      })
    ).toBe(false);

    expect(
      decodeInteractiveHtmlDescriptor({
        type: "document",
        mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
        data: btoa(JSON.stringify({ version: 1 }))
      })
    ).toBeNull();

    expect(
      decodeInteractiveHtmlDescriptor({
        type: "document",
        mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
        data: "%%%not-base64%%%"
      })
    ).toBeNull();
  });
});
