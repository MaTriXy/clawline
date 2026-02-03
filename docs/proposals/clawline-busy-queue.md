# Clawline busy + retry queue (proposal)

## Summary

Introduce a small, bounded per-session queue inside Clawline. New inbound messages are accepted up to a cap and retried on JSONL lock contention. When the cap is exceeded, the server returns a structured busy response so clients can show a busy state and keep messages pending. This preserves the two-phase client UX (pending until assistant response) without silently dropping or endlessly queueing messages.

## Goals

- Prevent JSONL lock failures from surfacing as hard errors for normal bursts.
- Preserve sessionKey-only routing and Clawline isolation (no core changes).
- Allow the client to show a busy state and retry later.
- Keep latency low for the common case.
- Maintain idempotency and avoid duplicate agent runs.

## Non-goals

- Global core queue or cross-provider scheduling.
- Durable queue across process restarts (optional later).
- Changing core delivery semantics or sessionKey routing rules.

## Current behavior (problem)

- Clawline inbound messages run immediately.
- If a run hits JSONL lock contention, the request fails and the client sees a generic error.
- Alerts are always enqueued, but normal inbound messages are not.

## Proposed behavior

### Server-side

- Maintain an in-memory per-session queue.
- On inbound message:
  - If session is idle and queue empty: run immediately.
  - If session is busy or lock contention is detected: enqueue.
  - If queue depth >= MAX_QUEUE_DEPTH: return a structured busy error.
- When a run completes, drain the queue (one at a time).
- On JSONL lock timeout or related transient failure:
  - Re-queue the current message with exponential backoff (with jitter).
  - If retries exceed a cap or TTL, mark as failed and notify the client.

### Client-side (two-phase)

- Sending a message creates a local PENDING entry.
- Server ACK indicates receipt, not completion.
- Client transitions to FINAL only when assistant output arrives.
- If server returns BUSY, client keeps message in PENDING and shows busy UI.
- If server returns FAILED, client marks FAILED and allows retry.

## Suggested protocol additions

### Server -> client events

- `message_status` (new)
  - `messageId`
  - `status`: `queued | busy | finalized | failed`
  - `reason` (optional)

### Client -> server

- No new required fields. Retry behavior stays on the client (resend same messageId).

### Error codes

- `busy`: queue is full or session is busy and cannot accept more.
- `retryable_lock`: transient JSONL lock conflict; request is queued.

## Queue details

### Keying

- Queue is per `sessionKey`.

### Capacity

- `MAX_QUEUE_DEPTH` (default 3-5). Hard cap.

### Backoff

- Start at 250ms, exponential up to 2-5s, jittered.
- Total TTL per message: 2-5 minutes.

### Idempotency

- Use `messageId` + content hash to dedupe.
- If the same `messageId` is already in-flight or queued, ignore or respond with current status.

### Ordering

- Preserve FIFO order per session key.

## Where this integrates (Clawline-only)

- `src/clawline/server.ts`
  - Wrap `processClientMessage()` entry point with the queue.
  - Add a lightweight queue manager per sessionKey.
  - Emit `message_status` events to the client.
- No changes to core outbound pipeline.

## Why this aligns with sessionKey routing

- Queue is keyed by sessionKey.
- No channelType parsing.
- No core changes.

## UX impact

- Single-message sends behave as before (immediate run).
- Bursts get queued with visible busy indicators.
- Failures are explicit and user-visible, not silent lock errors.

## Future enhancements (optional)

- Persist queue to disk for crash recovery.
- Surface queue depth in UI.
- Add a user-configurable maximum queue depth.

