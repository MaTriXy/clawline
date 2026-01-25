# Image send failure (server-side) — findings

## 1) Log evidence on TARS (2026-01-25 03:25:33 PST / 11:25:33Z)
- `~/.clawdbot/logs/gateway.log` shows a WebSocket message at **2026-01-25T11:25:33.939Z**:
  - `[plugins] [clawline:http] ws_message_received`
- Shortly after, the tracker entry (same log) records the exact server error:
  - `Send failed with server error: invalid_message (Missing content)`
  - Client log timestamp matches **2026-01-25 03:25:33 -0800**

Relevant log excerpt (line numbers in gateway.log on TARS):
- `197020`: `2026-01-25T11:25:33.939Z [plugins] [clawline:http] ws_message_received`
- `197054`: `Send failed with server error: invalid_message (Missing content)`

## 2) Server code path & validation
In `clawdbot/src/clawline/server.ts`, incoming WebSocket messages are validated in `processClientMessage`.
Key check (current code):
```ts
if (typeof payload.content !== "string" || payload.content.length === 0) {
  throw new ClientMessageError("invalid_message", "Missing content");
}
```
This fires **before** attachments are validated.

## 3) Why “Missing content” was returned
The client sent a message with **attachments but empty content**. The provider currently **requires non-empty content** regardless of attachments, so it throws `invalid_message (Missing content)`.

## 4) Is this a provider bug?
Likely **yes**, if attachment-only messages are intended/allowed (which matches current iOS design and UX). The server is enforcing a text requirement that conflicts with sending an image-only message.

### Proposed fix (server-side)
Allow `payload.content` to be empty **if** `attachments` is non-empty. This aligns with attachment-only message UX.

Notes / nits from review to incorporate in implementation:
- `normalizeAttachmentsInput` can throw if attachments are malformed. This should still be ok (prefer `invalid_message` over a misleading `Missing content`), but be explicit about the ordering.
- Treat whitespace-only content as “empty” (`trim()`), so `"   "` does not count as content.
- Ensure `attachments: []` with empty content still fails.
- Confirm `attachments` being `undefined` is handled as no attachments.
- Check downstream paths for any assumptions that `content` is non-empty.

Pseudo:
```ts
const rawContent = typeof payload.content === "string" ? payload.content : "";
const hasContent = rawContent.trim().length > 0;
const attachmentsInfo = normalizeAttachmentsInput(payload.attachments, config.media);
if (!hasContent && attachmentsInfo.attachments.length === 0) {
  throw new ClientMessageError("invalid_message", "Missing content");
}
```

## Coordination note for iOS-1
This server-side validation is consistent with the observed error. If iOS sends empty `content` with a valid attachment, it will be rejected until the server check is relaxed.
