# Interactive HTML Bubbles

Agent-rendered UI inside chat bubbles with bidirectional callbacks over the existing WebSocket.

## Goal

Let the agent send arbitrary HTML/CSS/JS as a message. The client renders it in a WKWebView inside a bubble. User interactions (form submissions, button taps, etc.) call back to the agent's session through the existing WebSocket — no HTTP server, no TLS, no CORS, no relay.

## Invariants

1. **This feature must not affect existing web view behavior.** The existing `LinkPreviewView` and any other WKWebView-based bubbles must continue to function exactly as they do today. Interactive HTML bubbles must use their own `WKWebViewConfiguration`, their own `WKProcessPool`, and their own `WKContentRuleList`. No shared configuration, no shared process pool, no shared content rules. Do not refactor, consolidate, or "improve" existing web view code as part of this work.

## Non-Goals

- Server-side rendering or hosting of HTML content
- Persistent state across sessions (each bubble is self-contained)
- Replacing native UI components (this is for agent-generated dynamic content)
- Running arbitrary native code from JS (sandboxed to message handler bridge)
- Mutable/updatable bubbles (each bubble is immutable once sent; v2 consideration)
- Network access from bubble content (all content is inline and offline)

## Supersedes

T023 (HTML form submission UI) — the /inject endpoint + relay server approach. That code has been removed.

## Architecture

### Message Flow

```
Agent                    Provider              Client (iOS/visionOS)
  |                         |                         |
  |-- send message -------->|                         |
  |   contentType:          |-- WS: message --------->|
  |   application/vnd.      |                         |
  |   clawline.interactive  |                    [detect MIME type]
  |   -html+json            |                    [render WKWebView]
  |                         |                    [display in bubble]
  |                         |                         |
  |                         |                    [user interacts]
  |                         |                    [JS postMessage()]
  |                         |<-- WS: callback --------|
  |<-- session message -----|                         |
  |   (callback payload)    |                         |
```

### Content Type

```
application/vnd.clawline.interactive-html+json
```

### Message Payload (Agent → Provider → Client)

```json
{
  "version": 1,
  "html": "<html>...</html>",
  "metadata": {
    "title": "Quick Survey",
    "height": "auto",
    "maxHeight": 400,
    "backgroundColor": null
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | number | yes | Protocol version. Currently `1`. Client must reject unknown versions gracefully (show "Update required" message). |
| `html` | string | yes | Complete HTML document (inline CSS/JS). Self-contained — no external resource loading. Max 256KB. |
| `metadata.title` | string | no | Accessible label for the bubble. Not rendered visually by default. |
| `metadata.height` | string\|number | no | `"auto"` (default, sizes to content) or fixed px value. |
| `metadata.maxHeight` | number | no | Maximum bubble height in points. Content scrolls beyond this. Default: 400. |
| `metadata.backgroundColor` | string | no | Override bubble background. Null = inherit from theme. |

### Callback Protocol (Client → Provider → Agent)

When JS calls the native bridge:

```javascript
window.webkit.messageHandlers.clawline.postMessage({
  action: "submit",
  data: { name: "Flynn", mood: "good" }
});
```

The native app wraps this and sends over the existing WebSocket:

```json
{
  "type": "interactive-callback",
  "messageId": "<original-message-id>",
  "payload": {
    "action": "submit",
    "data": { "name": "Flynn", "mood": "good" }
  }
}
```

The provider delivers this to the agent's session as a message with both structured and human-readable content:

- **Content type:** `application/vnd.clawline.interactive-callback+json`
- **Structured payload:** The full callback JSON (action + data + source messageId)
- **Text fallback:** `[Interactive: "Quick Survey"] action=submit — {"name": "Flynn", "mood": "good"}`

The text fallback ensures the callback is visible in conversation history and readable by the agent without special parsing. The structured payload is available for programmatic handling.

#### Delivery Semantics

- **At-most-once, fire-and-forget:** Callbacks are best-effort and are not retried by the client.
- **No acknowledgement in v1:** The client does not wait for an ack/nack from the provider/agent.
- **Ordering:** WebSocket delivery is ordered, but **ordering is not guaranteed under rate limiting** (dropped callbacks break sequence). Interactive HTML must be designed assuming callbacks may be lost or re-ordered.

### JS Bridge API

The WKWebView exposes a single message handler:

```javascript
// Send a callback to the agent
window.webkit.messageHandlers.clawline.postMessage({
  action: "string",     // Required. Identifies the interaction type.
  data: { ... }         // Optional. Arbitrary JSON payload.
});

// Close the interactive bubble (collapse to summary)
window.webkit.messageHandlers.clawline.postMessage({
  action: "_close",
  summary: "Survey submitted ✓"  // Optional replacement text
});
```

**Reserved actions** (prefixed with `_`):
- `_close` — Collapse bubble, optionally replace with summary text
- `_resize` — Request height change: `{ height: 300 }`

All other action names are user-defined by the agent's HTML.

**Limits:**
- `action` string: max 128 characters
- `data` payload: max 64KB serialized JSON
- Rate limit: max 10 callbacks per second per bubble (excess silently dropped)

## Security

### Threat Model

Content is authored by a trusted agent and delivered over an authenticated WebSocket. The agent already has full session access — rendering HTML in a bubble does not expand its capabilities. The security measures here are **defense-in-depth** against accidental external resource loading, not protection against a malicious content author.

### Content Security Policy

The client injects a CSP meta tag wrapping all HTML before loading:

```html
<meta http-equiv="Content-Security-Policy" 
  content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:;">
```

This blocks all network-origin resources (images, scripts, stylesheets, fonts, iframes, fetch, XHR). Only inline content and `data:` URIs are allowed.

### WKContentRuleList (Defense-in-Depth)

In addition to CSP, a `WKContentRuleList` blocks all network requests as a second layer:

```json
[{
  "trigger": { "url-filter": ".*" },
  "action": { "type": "block" }
}]
```

### WKWebView Configuration

Each interactive bubble uses a sandboxed WKWebView with:

- **Non-persistent data store:** `WKWebsiteDataStore.nonPersistent()` — no cookies, no localStorage, no IndexedDB persistence
- **Separate process pool:** Own `WKProcessPool`, not shared with `LinkPreviewView` or any other web views
- **Separate configuration:** Own `WKWebViewConfiguration` instance
- **Base URL:** `nil` — no origin, no file access, no credential leakage
- **No navigation:** `WKNavigationDelegate` blocks all navigation except initial `loadHTMLString`. This includes `window.open()`, `javascript:` URLs, `data:` URLs, `blob:` URLs, meta refresh, `location.href`
- **No UI delegates:** `WKUIDelegate` suppresses `alert()`, `confirm()`, `prompt()`, `window.open()` (returns nil)
- **No media capture:** Camera/microphone access denied
- **No pasteboard:** Clipboard API not available (non-persistent data store, no user gesture bypass)

### Content Size Limit

HTML payload is hard-capped at **256KB**. Enforced at:
- **Provider:** Rejects messages with HTML content exceeding 256KB before delivery
- **Client:** Rejects payloads exceeding 256KB if they somehow arrive

## Bubble Rendering

### Sizing

- Width: same as other bubbles (max bubble width from layout system)
- Height: `auto` by default — measured via JS after load (see Sizing Protocol below)
- If content exceeds `maxHeight`, the web view scrolls internally
- Minimum height: 44pt (one tap target)

### Sizing Protocol

To avoid the layout jitter we've seen in T020/T026/T028:

1. **Initial load:** Render WKWebView at full bubble width, hidden (alpha 0), at minimum height
2. **Measure:** After `webView(_:didFinish:)`, evaluate JS: `document.body.scrollHeight`
3. **Lock height:** Set bubble height to `min(measured, maxHeight)`. This is the final height — no further resizing from content changes
4. **Reveal:** Animate alpha to 1 and invalidate the flow layout cell size
5. **No ResizeObserver:** Do not use continuous resize observation. One measurement, one layout pass. If content changes size after load (e.g., JS animations), it scrolls within the locked height
6. **`_resize` escape hatch:** The `_resize` reserved action allows a one-time JS-initiated height change if the content explicitly requests it. This triggers one additional measure-lock-invalidate cycle, then locks again. The client must honor **at most one** `_resize` per bubble lifetime; subsequent `_resize` requests are ignored.

This avoids feedback loops by design: measure once, lock, done.

### Theming

The client injects CSS variables before rendering so HTML can adapt to the current theme:

```css
:root {
  --clawline-bg: #1a1a1a;
  --clawline-fg: #ffffff;
  --clawline-accent: #007AFF;
  --clawline-bubble-bg: #2a2a2a;
  --clawline-font-family: -apple-system, system-ui;
  --clawline-font-size: 16px;
}
```

Agents can use these or ignore them.

### Loading State

1. Show a placeholder at minimum height (44pt) with a subtle pulse/shimmer
2. Once height is measured and locked, animate to final height and reveal content
3. If load fails or JS errors, show error state: "Content failed to render"

### Error & Crash Recovery

- **`webViewWebContentProcessDidTerminate:`** — Show "Content crashed" with a Reload button. Auto-reload once; if it crashes again, show permanent error state
- **JS errors** — Log via `WKNavigationDelegate` error callbacks. Do not surface to user unless render fails entirely
- **Unknown version** — Show "Update Clawline to view this content" instead of attempting render

## Performance

### WKWebView Lifecycle

- **Cell reuse:** `InteractiveHTMLBubbleView` participates in normal UICollectionView cell reuse. WKWebView is created on bind, torn down on prepareForReuse
- **No pooling in v1:** Keep it simple. If performance is a problem with many interactive bubbles on screen, add WKWebView pooling in v2
- **Memory warnings:** On `didReceiveMemoryWarning`, tear down offscreen interactive bubble WKWebViews. They recreate on next scroll-into-view

## Implementation Scope

### Provider (extension only)

1. Recognize `application/vnd.clawline.interactive-html+json` content type on outbound messages
2. Enforce 256KB size limit — reject oversized payloads
3. Pass content through to client over WebSocket (no transformation)
4. Handle `interactive-callback` WS messages from client → deliver to agent session with both structured content type and text fallback
5. New WS message type: `interactive-callback`

### Client (iOS/visionOS)

1. New bubble type: `InteractiveHTMLBubbleView`
2. WKWebView setup per Security section (own config, own process pool, CSP, content rules)
3. CSS variable injection for theming
4. `WKScriptMessageHandler` for the `clawline` message handler
5. Sizing protocol: measure once after load, lock height, reveal
6. Callback validation (action length, data size, rate limit) before sending over WS
7. Error states: load failure, crash recovery, unknown version
8. `_close` action: collapse bubble, replace with summary text
9. `_resize` action: one-time height adjustment

### Agent (no changes)

Agents send messages with the right content type. The gateway/core doesn't need to know or care — it's opaque message content.

## Relationship to Other Work

- **Terminal bubbles (T001):** Same pattern — special MIME type → custom bubble renderer. But terminal bubbles use SwiftTerm, these use WKWebView.
- **T022 (UIs that aren't UIs):** Interactive HTML bubbles are the implementation mechanism for convention-based interaction.
- **Bubble sizing (T028/T020):** Web view sizing lessons apply. The sizing protocol above is specifically designed to avoid the layout feedback loops fixed in those items.
