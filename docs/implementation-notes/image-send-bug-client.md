# Image send failure investigation (iOS)

## Summary
The `invalid_message` server response is treated as a *connection-level* failure when it lacks a `messageId`. That sets the connection state to `.failed`, which triggers the reconnect pipeline. The reconnect path forcefully disconnects the socket (`teardownConnection` → `performDisconnect`), and that disconnect clears pending messages **without emitting per-message error events**. As a result, the optimistic “You” placeholder/bubble can remain even though the send failed.

---

## Evidence in code

### 1) Disconnect on message send failure
**File:** `ios/Clawline/Clawline/Services/ProviderChatService.swift`

- `handleServerError` has two paths:
  - If `payload.messageId` is present: it removes `pendingMessages[messageId]` and emits `.messageError` **without** changing connection state.
  - If no `messageId`: it calls `updateState(.failed(Error.serverError(...)))` for default cases.

```swift
if let messageId = payload.messageId {
    // emits .messageError and returns
    return
}
...
// inside default case of switch over payload.code
updateState(.failed(Error.serverError(code: payload.code, message: payload.message)))
```

**Result:** a *message-level* error becomes a *connection-level* failure when the server omits `messageId`.

**File:** `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`

`handleConnectionState(.failed)` always calls `scheduleReconnect(reason: .connectionStateFailed)`.

`scheduleReconnect` calls `chatService.connect` which begins with:

```swift
try await teardownConnection()
// -> performDisconnect(...)
// -> socket closed + updateState(.disconnected)
```

So the flow is:
1. server error without `messageId`
2. ProviderChatService updates state to `.failed`
3. ChatViewModel schedules reconnect
4. reconnect calls `connect`
5. `connect` calls `teardownConnection` → `performDisconnect`
6. socket closed + `.disconnected`

This explains why a message send failure causes a disconnect, even though the error is not connection-fatal.

### 2) Bubble gets posted even after error
**File:** `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`

`send()` always adds an optimistic placeholder message **before** send:

```swift
appendMessage(placeholder)
pendingLocalMessages.append(...)
```

The placeholder is only removed in `handle(serviceEvent:)` when it receives `.messageError`:

```swift
case .messageError(let messageId, ...):
    removePlaceholder(withId: messageId)
```

**Problem:** When the server error lacks `messageId`, `ProviderChatService` never emits `.messageError`. That means the placeholder stays, which looks like a bubble being posted even though the send failed.

**Additional issue:** `performDisconnect` clears `pendingMessages` **without** emitting `.messageError` for those IDs. The only place that emits `messageError` for pending messages is `handleSocketClose`, but `performDisconnect` cancels and clears pending messages *before* socket-close handling runs. This creates a deterministic gap where neither error path fires, leaving placeholders orphaned.

So error path becomes:
- optimistic placeholder added
- server error without messageId → `.failed`
- reconnect path disconnects immediately
- pending messages cleared silently
- placeholder remains

---

## Theory: what’s wrong
1. **Server error isn’t correlated to a message ID**, so the client treats it as a connection-level failure.
2. **Connection-level failure forces a reconnect**, which disconnects the socket (even though the server only rejected a single message).
3. **Pending message cleanup on disconnect is silent**, so the optimistic UI bubble is never removed.

---

## Likely fixes (not implemented here)
- **Client (preferred):** Emit `.messageError` for all entries in `pendingMessages` inside `performDisconnect` to avoid orphan placeholders. (Alternative: defer clearing to `handleSocketClose`.)
- **Client:** Treat specific codes (`invalid_message`, `payload_too_large`, `invalid_channel`) as message-level failures even **without** `messageId`, so they don’t force a disconnect.
- **Server:** Always include `messageId` on message-level error responses so the client can correlate and avoid `.failed` state.
