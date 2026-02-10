# Message Routing Investigation — 2026-02-04

## Incident
A status message (about ios-3 being complete/idle) appeared in Flynn's **Personal** stream instead of the admin chat where the conversation was happening.

## Investigation

### Session Key Structure
- Parent session: `agent:main:main` or `agent:main:clawline:flynn:main`
- Subagent session: `agent:main:subagent:<uuid>`

**Key insight:** Subagent keys are derived as `agent:<agentId>:subagent:<uuid>`. They do NOT preserve the parent session's routing suffix (e.g., `clawline:flynn:main`). This means there's no way to derive the parent's delivery context from the subagent key alone.

### Evidence from Gateway Logs
From route-trace analysis in `~/.openclaw/logs/gateway.log`:

1. **Session key mismatch confirmed:**
   > "The completion payload that contained the `ios-3 … IDLE` status was tagged with `agent:main:subagent:a458…`, not the main chat key"

2. **No tmux agent notify found:**
   > "I found no evidence that this specific message came from a coding agent `notify --session agent:main:main …`"

3. **Missing delivery context:**
   > "The gateway also shows a failure delivering to clawline due to missing `--to`, which suggests the system didn't have an explicit delivery context for where that completion should go"

4. **Clawline routing behavior:**
   > "In Clawline, stream selection/routing is sessionKey-driven; a non-DM/non-admin sessionKey is very plausibly treated as 'personal/default' by either the provider or the iOS client's session→stream mapping."

### Two Cases Identified

**Case 1: Subtask does work itself and reports back**
- Uses auto-announce or sessions_send
- ASSUMPTION: Should work fine as core platform behavior
- OPEN QUESTION: Does this actually work for Clawline? The evidence suggests the misrouted message may have been case 1, not case 2.

**Case 2: Subtask directs a tmux agent via submitter**
- Subtask calls submitter with a session key
- tmux agent eventually runs `notify --session <key>`
- If subtask passes its OWN key (`agent:main:subagent:...`), the notify will misroute because Clawline can't resolve that key to a stream

### Root Cause (Partial)
For **case 2**, the fix is clear: when spawning a subtask that might use submitter, pass the parent's session key explicitly and instruct the subtask to use THAT key with submitter.

For **case 1**, it's unclear:
- Is case 1 affected by Clawline's session key routing at all?
- If so, what's the failure mode and fix?

### What We Don't Know
1. Was the misrouted message actually case 1 or case 2?
2. If case 1, why did it fail? The subtask's own completion shouldn't need Clawline-specific routing—it should go back to the spawning session via core platform mechanisms.
3. Does the core platform auto-announce actually work correctly with Clawline's delivery model?

### Actions Taken
1. Updated `agent-dispatch` skill with case 2 fix: pass parent session key to subtasks that may use submitter
2. Updated TRACKER with summary

### Case 1 Test Results (15:45 PST)

**Test:** Spawned `routing-test-case1` subtask that completes normally without explicit routing.
- Session key: `agent:main:subagent:55cb216d-4f2e-44d2-b950-227854ec8082`
- Subtask completed successfully (verified via `sessions_history`)
- Flynn did NOT receive the auto-announce

**Gateway log analysis:**
```
face_speak_decision ... decision=attempt reason=ok
face_speak_triggered
face_speak_failed
```

**Key finding:** No `sendOutboundMessage` log for the subagent delivery. Working deliveries show:
```
sendOutboundMessage using admin channel from sessionKey=agent:main:main
```

**Root cause:** Clawline routing matches session keys to channels:
- `agent:main:main` → admin channel
- `agent:main:clawline:*` → personal/DM channel
- `agent:main:subagent:*` → **NO MATCH → silent failure**

**Conclusion:** Case 1 (subtask auto-announce) is BROKEN for Clawline. The subagent session key doesn't match any routing pattern, so delivery silently fails.

### Fix Options
1. **Clawline provider fix:** Add routing rule for `agent:main:subagent:*` → parent session's channel (requires provider to track parent relationship or extract from key)
2. **CLU workaround:** Always use explicit `sessions_send` to parent key in subtask prompts (both case 1 and case 2)
3. **Platform fix:** Auto-announce should use parent session's delivery context, not subagent's

### Next Steps
- File GitHub issue for Clawline provider routing fix
- Update agent-dispatch skill: ALL subtasks need explicit routing for Clawline, not just case 2

---

## Sub-Investigation: Is this Clawline-specific or a core platform issue?

**Flynn's question (16:00 PST):**
> "If we were to completely pull Clawline out (so the code is just upstream), would subtask waking the parent session still be broken?"

**CLU's assumption challenged:**
CLU observed Clawline's `face_speak_triggered` → `face_speak_failed` and concluded Clawline routing was the issue. But `face_speak` is Clawline's TTS/delivery mechanism—not necessarily the core platform's auto-announce.

**Unknown:**
- Does the core platform auto-announce (A) send completion into parent session (which then delivers via parent's channel), or (B) try to deliver directly using subtask's own context?
- If A, Clawline might be irrelevant—completion should land in parent session and deliver normally
- If B, there's a core platform issue

**Action:** Asked clawline-provider to investigate whether this is Clawline-specific or upstream behavior.

**Result (16:20 PST):** Provider examined `src/agents/subagent-announce.ts` in upstream OpenClaw.

**Answer: A — Core platform sends completion into parent session.**

The auto-announce flow:
1. Builds announce message
2. Calls `callGateway({ method: "agent", params: { sessionKey: requesterSessionKey, channel/to/accountId from requesterOrigin, deliver: true } })`
3. If agent busy, queues announce keyed by requester's session key, using `requesterOrigin` for routing
4. **Never** uses the child `agent:main:subagent:<uuid>` key for delivery

**CLU's assumption was wrong.** The failure is NOT because Clawline doesn't recognize subagent keys—the platform doesn't even use them for delivery. It always uses `requesterSessionKey` + `requesterOrigin`.

**Status:** Sub-investigation complete. Moved to next sub-investigation.

---

## Sub-Investigation 2: Orphan Session Creation

**Finding (17:00 PST):** The announce landed in session `session_9f402012-5a98-484e-86e1-d16413965d64`.

**What we found about this session:**
- Created at `23:42:43.781Z` — exact moment subtask completed
- Only 7 lines total (session init + announce + NO_REPLY response)
- No system prompt
- No conversation history
- No sessionKey mapping in sessions.json
- No delivery context
- Agent had zero context, decided "looks like internal test," replied NO_REPLY

**This is an orphan session** — created just to handle the announce, with no connection to the parent session (`agent:main:main`).

**Question:** Under what circumstances can the code create such an orphaned session? What code path leads to this instead of injecting the announce into the existing parent session?

**Action:** Asked provider to investigate session creation in announce flow.

**Result (18:30 PST):** Provider traced the full code path.

---

## Sub-Investigation 3: Mirror Path Clarification

**Flynn's question:** Discord also doesn't use the mirror path — is it broken for them too?

**Provider findings:**
- **Mirror is a red herring** — it only appends to transcripts, does NOT create session store entries
- Discord works because its **inbound pipeline creates core session store entries**
- Clawline fails because its inbound pipeline **doesn't write to core session store**

**Root cause confirmed:** Clawline must update the core session store on inbound messages.

---

## Sub-Investigation 4: What Does Clawline's SQLite Actually Store?

**Flynn's question:** Do we even need our own DB or should we make session store canonical?

**Clawline SQLite tables:**
```sql
user_sequences (userId, nextSequence)        -- event ordering per user
events (id, userId, sequence, payloadJson, timestamp, ...)  -- event log
messages (deviceId, userId, clientId, serverEventId, content, ackSent, ...)  -- iOS sync state
assets (assetId, userId, mimeType, size, ...)  -- uploaded media
message_assets (deviceId, clientId, assetId)  -- links messages to assets
```

**Finding:** Clawline's SQLite stores **different data** than the core session store:
- SQLite: event sequencing, message sync state for iOS devices, asset tracking
- Core session store: session key → session ID mapping, delivery context

**These are not duplicates.** Clawline needs its SQLite for iOS sync functionality AND needs to update the core session store for announce to work.

---

## ⛔ IGNORE face_speak logs

`face_speak_triggered` / `face_speak_failed` are for TTS/audio features, NOT message delivery. They have nothing to do with routing. Do not cite them as evidence of delivery issues.

---

## Final Root Cause

Clawline's inbound pipeline doesn't call `updateSessionStore()` (or equivalent) to register sessions in the core store. When subagent announce runs, `loadSessionEntry()` returns nothing, gateway creates orphan session.

## Fix

Clawline needs to update the core session store on inbound messages — same as Discord's inbound pipeline does. This is additive (keep SQLite for iOS sync, add core store update for announce).

---

## Sub-Investigation 5: Discord Pattern Analysis (20:45 PST)

**Question:** What exactly does Discord do that Clawline doesn't?

### Discord's Inbound Pattern

Discord sets **two separate things** for delivery routing:

1. **`OriginatingTo`** — Set to `replyTarget` which is `channel:<channelId>` (the delivery target format for Discord)
   ```javascript
   OriginatingTo: autoThreadContext?.OriginatingTo ?? replyTarget,
   // replyTarget = `channel:${message.channelId}`
   ```

2. **`recordInboundSession({ updateLastRoute })`** — Explicitly sets `lastTo` in session store
   ```javascript
   await recordInboundSession({
     storePath,
     sessionKey: ctxPayload.SessionKey ?? route.sessionKey,
     ctx: ctxPayload,
     updateLastRoute: isDirectMessage
       ? {
           sessionKey: route.mainSessionKey,
           channel: "discord",
           to: `user:${author.id}`,
           accountId: route.accountId,
         }
       : undefined,
     onRecordError: ...
   });
   ```

**Key insight:** Discord separates two concerns:
- `OriginatingTo` = channel target for reply routing (format: `channel:<id>`)
- `updateLastRoute.to` = user target for session-level routing (format: `user:<id>`)

### Clawline's Current (Broken) Pattern

Clawline sets `OriginatingTo` but does NOT call `recordInboundSession`:

```javascript
// Line 3101 in server.ts
OriginatingTo: `user:${session.userId}`,  // → "user:flynn"
```

The auto-reply session code then uses this to set `lastTo`:

```javascript
// src/auto-reply/reply/session.ts lines 246-247
const lastToRaw = ctx.OriginatingTo || ctx.To || baseEntry?.lastTo;
// → This becomes "user:flynn" and gets written to lastTo
```

**Problem:** Even though `updateClawlineSessionDeliveryTarget` sets `lastTo: sessionKey` (the full `agent:main:clawline:flynn:main`), the auto-reply code overwrites it with `ctx.OriginatingTo` → `"user:flynn"`.

### Two Issues Identified

1. **Missing `recordInboundSession` call** — Clawline doesn't call it at all (Discord does)
2. **`OriginatingTo` clobbers `lastTo`** — The auto-reply code uses `OriginatingTo` as first choice for `lastTo`, overwriting what `updateClawlineSessionDeliveryTarget` set

### Fix Options

**Option A (Quick fix):** Change line 3101 to set `OriginatingTo: resolvedSessionKey` instead of `user:${userId}`
- This works because auto-reply will then write the correct session key to `lastTo`
- Not exactly Discord's pattern, but achieves the goal

**Option B (Discord-aligned fix):** Add `recordInboundSession` call in `processClientMessage`
- Call it right after `ctxPayload` is created
- Use `updateLastRoute: { sessionKey: route.sessionKey, channel: "clawline", to: sessionKey }`
- This is the "sound" fix that matches Discord's pattern

**Recommendation:** Option B — properly aligns with Discord and handles both `origin`/`deliveryContext` population AND `lastTo` setting in one call. The provider agent already has the exact code changes mapped out.

---

## Sub-Investigation 6: lastTo Deep Dive (2026-02-05 00:00 PST)

### Refactor Deployed

The provider implemented Option B — `recordInboundSession` is now called in `processClientMessage`:

```javascript
const deliveryTarget = ClawlineDeliveryTarget.fromParts(session.userId, "main");
// ...
await recordInboundSession({
  // ...
  updateLastRoute: {
    sessionKey: route.sessionKey,
    channel: "clawline",
    to: deliveryTarget.toString(),  // → "flynn:main"
    accountId: route.accountId,
  },
});
```

Session store now shows:
- `lastTo`: `"flynn:main"` (changed from `"user:flynn"`)
- `lastChannel`: `"clawline"`
- `deliveryContext.to`: `"flynn:main"`

### Test Results: Still Broken

Spawned test subtask from admin chat (`agent:main:main`). Result:
- Announce was injected into parent session ✓
- CLU received the announce ✓
- **Outbound message appeared in PERSONAL stream, not admin** ✗

The routing fix didn't fix the actual problem.

### Key Discovery: lastTo ≠ Session Key

**Critical insight:** `lastTo` and session keys are completely orthogonal concepts.

- **Session key** (`agent:main:main`) = which conversation/context
- **lastTo** (`user:123`, `channel:456`, `flynn:main`) = channel-specific delivery address

They are NOT related. `lastTo` is not an abbreviation of a session key. It's a delivery target that the channel interprets.

### Discord's Pattern Clarified

Discord uses `lastTo` to encode WHERE to deliver:
- **DM:** `lastTo = "user:<discordUserId>"` — Discord interprets this as "send DM to this user"
- **Channel:** `lastTo = "channel:<channelId>"` — Discord interprets this as "send to this channel"

The `lastTo` value itself encodes the destination type. Discord's outbound resolver parses `user:` vs `channel:` to decide routing.

### Core's lastTo Behavior

Provider investigation findings:

1. **When core sets lastTo:**
   - Set whenever inbound has `OriginatingTo` or `To`
   - Via `recordInboundSession` → `updateLastRoute`
   - Unset for internal flows (cron/hook) or if provider doesn't set those fields

2. **What lastTo is for:**
   - Last delivery target for a session, paired with `lastChannel`
   - Used by: `resolveSessionDeliveryTarget`, `resolveAgentDeliveryPlan`, `resolveHeartbeatSenderContext`, `resolveAnnounceTarget`
   - NOT a session key — it's a channel-specific destination string

3. **lastTo IS set for main/DM sessions:**
   - Discord DMs on main: `lastTo = user:<discordUserId>`
   - Telegram DMs on main: `lastTo = <chatId>`
   - Channels DO set `lastTo` on main session

### dmScope Config

`session.dmScope` is a core OpenClaw config (not Discord-specific):
- `main` (default): All DMs share `agent:main:main`, `lastTo` flips between users
- `per-peer`: Creates distinct keys like `agent:main:dm:<userId>`

By default, Discord shares main session for all DMs and uses `lastTo` to track which user to reply to.

### OriginatingTo vs To

- **To:** Raw destination from inbound payload (provider-specific)
- **OriginatingTo:** Normalized reply target for routing replies back to origin. Core uses this for announce and implicit routing.

**Clawline iOS client doesn't set either.** These are server-side fields built in `src/clawline/server.ts` (`finalizeInboundContext`).

### The Actual Bug: OriginatingTo is Hardcoded

```javascript
// src/clawline/server.ts
const deliveryTarget = ClawlineDeliveryTarget.fromParts(session.userId, "main");
const ctxPayload = finalizeInboundContext({
  // ...
  OriginatingTo: deliveryTarget.toString(),  // → "flynn:main"
});
```

**This is hardcoded to `{userId}:main` for ALL inbound messages** — regardless of whether they come from admin or personal stream.

- Admin message → `OriginatingTo = flynn:main`
- Personal message → `OriginatingTo = flynn:main`
- Both the same!

This flows to `lastTo`, so admin and personal both get `lastTo = flynn:main`. When outbound delivery uses `lastTo`, it routes to personal regardless of which stream the conversation is in.

### Clawline's Conceptual Model

Flynn explained Clawline's intent:

1. **Admin/DM session** (`agent:main:main`): Central session cross-cutting all users. Accessible by users with `isAdmin` flag. Intentionally shared.

2. **Personal sessions** (`flynn:main`, `flynn:finances`): Per-user, per-channel sessions. Private to each user.

3. **dmScope** can separate DM into per-user sessions, but that makes it behave like personal — no longer targeting `agent:main:main`.

### Current State

The refactor correctly wired up `recordInboundSession` and `lastTo` is now being set. But Clawline sets the SAME `OriginatingTo` value for admin and personal messages.

For Discord, `lastTo` encodes the destination (`user:X` vs `channel:Y`). What should Clawline's model be?

### OriginatingTo and To: Core Contract (01:05 PST)

**What they are:**
- **To:** Raw destination from inbound payload (provider-specific)
- **OriginatingTo:** Normalized reply target for routing replies back to origin

**Who sets them:**
- Neither is set by the client (iOS app, Discord client, etc.)
- Both are **server-side fields** built by the provider code when wrapping inbound messages
- The client sends a message; the provider server decides what `OriginatingTo` should be

**Core's contract (from code comments/usage):**
- `OriginatingTo` = "destination for reply routing"
- Replies route based on `OriginatingChannel/OriginatingTo`, not `lastChannel`
- Part of session metadata (`origin.to`), not just transient routing
- No dedicated doc file — contract is implicit in code

**All providers set OriginatingTo server-side:**
- Discord: `OriginatingTo: replyTarget` (computed from channel/DM)
- Telegram: `OriginatingTo: telegram:${chatId}`
- Slack: `OriginatingTo: slackTo`
- iMessage/Signal/Web/Line — all compute it server-side
- **None pass through a client-provided value**

**Is Clawline following the pattern?**
- Yes. Setting `OriginatingTo` server-side matches the canonical pattern.
- The question is: what VALUE should Clawline compute for admin vs personal?

---

### Open Questions

1. **Is Clawline's abstraction correct?** We assumed `lastTo` should encode admin vs personal. But maybe the whole model is wrong.

2. **How SHOULD Clawline map to core concepts?**
   - Session keys: `agent:main:main` (admin) vs `agent:main:clawline:flynn:main` (personal)
   - lastTo: Currently both get `flynn:main`. Should they differ? What values?
   - Or is lastTo not the right mechanism for this?

3. **Does the iOS client send anything indicating admin vs personal?** Or does the server infer it from session/route?

4. **What IS admin vs personal in Clawline?**
   - Two sessions? Two delivery targets? Two UI views of the same thing?
   - How should they map to core's session + lastTo model?

5. **Should admin messages even set lastTo?** Admin is a shared cross-user session. Maybe it shouldn't have a user-specific delivery target at all?

We are still investigating. No fix proposed until the model is understood.

---

## Verification Test: Session Store Fix (2026-02-05 08:24 PST)

### Pre-Test State

Queried session store for `agent:main:main`:

```json
{
  "lastTo": "user:flynn",
  "lastChannel": "clawline",
  "lastAccountId": "default",
  "sessionFile": "/Users/mike/.clawdbot/clawline/sessions/agent-main-main.jsonl"
}
```

**Finding:** `lastTo` is now populated with `user:flynn`. The `recordClawlineSessionActivity` fix is writing to the session store.

### Test Execution

Spawned subtask to test completion routing:
- **Task:** Simple completion message ("Subtask routing test complete")
- **Label:** `routing-test`
- **Child session key:** `agent:main:subagent:3c62c0bf-7855-487d-b83b-fef8e723d0c2`
- **Spawned at:** 2026-02-05 08:24 PST

### Expected Outcome

If fix works: Completion announcement arrives in admin chat (where the spawn was initiated).

If fix fails: Completion goes to orphan session or personal stream.

### Results

*(pending — waiting for subtask to complete)*

---

## References
- TRACKER.md: "Message Routing Regression" section
- agent-dispatch skill: `sessions_spawn Tasks` section
- Gateway logs: `~/.openclaw/logs/gateway.log` (search "personal" or "missing.*--to")
