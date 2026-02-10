# Clawline Busy Queue Bug - Investigation Results

**Date:** 2026-01-23
**Investigator:** CLU (proactive session)

## Problem
When CLU is busy processing, messages sent from iOS Clawline don't make it through. Discord queues messages in this scenario, but Clawline does not.

## Investigation Findings

### 1. Queue Infrastructure EXISTS and is Shared
Both Discord and Clawline use the same queueing system:
- `dispatchReplyFromConfig` → `runReplyAgent` → `enqueueFollowupRun`
- Default queue mode for all channels: `"collect"`
- Queue settings: debounce 1000ms, cap 20, dropPolicy "summarize"

The queueing code is channel-agnostic - Clawline should queue just like Discord.

### 2. Message Flow Analysis (Clawline server.ts)
```
WebSocket message received
  → persistUserMessage (stores to SQLite)
  → send ack to client
  → dispatchReplyFromConfig
    → runReplyAgent
      → if isActive && shouldFollowup → enqueueFollowupRun
  → check queueDepth
  → if !wasDelivered && !wasQueued → mark Failed
```

### 3. Key Difference: Session State Tracking
The `isActive` check uses `isEmbeddedPiRunActive(sessionId)` which checks `ACTIVE_EMBEDDED_RUNS.has(sessionId)`.

**Potential issue:** If the sessionId format is different for Clawline (e.g., `agent:main:clawline:dm:flynn` vs `agent:main:main`), the "busy" state tracking might not match.

### 4. Symptom Analysis
> "On app relaunch, those bubbles are gone - never persisted"

This suggests one of:
1. Server never received message (WebSocket drop during busy period)
2. Server received but didn't ack (error before ack sent)
3. iOS app not persisting sent messages locally until ack

### 5. Most Likely Root Cause
The ack is sent AFTER `persistUserMessage`:
```typescript
const { event } = await persistUserMessage(...);
await new Promise<void>((resolve) => {
  session.socket.send(JSON.stringify({ type: "ack", id: payload.id }), ...);
});
```

If `persistUserMessage` fails or the WebSocket connection is interrupted during the busy period (e.g., server is under high load), the ack never reaches the client.

## Recommended Fix

### Option A: Client-Side Resilience (iOS)
- Persist sent messages locally BEFORE sending over WebSocket
- Mark as "pending" until ack received
- Show retry UI if ack not received within timeout
- On reconnect, resend pending messages

### Option B: Server-Side Queue Before Dispatch
Currently: `persist → ack → dispatch (may queue)`
Proposed: `persist → ack immediately → dispatch asynchronously`

This ensures the client gets an ack as soon as the message is stored, regardless of whether CLU is busy.

### Option C: Add Logging to Diagnose
Add specific logging at each step:
- When message received (timestamp)
- When persist completes/fails
- When ack sent
- When dispatch starts
- When enqueue happens (if busy)

Then reproduce the issue and trace the logs.

## Next Steps
1. Add diagnostic logging (Option C) to confirm exact failure point
2. Implement client-side resilience (Option A) for robustness
3. Consider Option B if server-side latency is the issue

## Related Files
- `/Users/mike/src/clawdbot/src/clawline/server.ts` (lines 1915-2160)
- `/Users/mike/src/clawdbot/src/auto-reply/reply/queue/drain.ts`
- `/Users/mike/src/clawdbot/src/auto-reply/reply/agent-runner.ts` (lines 180-195)
