# Chat IA Spec - Implementation Questions / Gaps

Source spec: `chat-information-architecture.md` (Last reviewed 2026-02-06)

This is an implementer-focused review: concrete questions that matter when wiring client <-> provider <-> core.

## Status

The spec is close to implementable as-written. The main remaining gaps are: (1) clarifying the exact wire/session provisioning handshake and which side owns which fields at bootstrap, and (2) nailing down the exact on-wire values for Clawline delivery targets (OriginatingTo/updateLastRoute.to) for the three streams, including how the provider must map them back to session keys on outbound.

## Questions / Gaps

### 1) Session provisioning handshake (client <-> provider)

1. What is the exact connect/auth call sequence and message shapes for returning the per-stream resolved session keys to the client?
   - The spec says “client asks core what is my DM session” and “provider must receive resolved key from core” but doesn’t specify whether this is part of `auth_result` (connect ack) vs a separate RPC.

2. What exact fields does the client send on first message for each stream?
   - The spec strongly prefers sessionKey-opaque to the client, but we still need a bootstrap flow for a brand-new install/session-cache-miss.
   - Concretely: does the client send only `stream` (not allowed by N7), only `sessionKey` (but may not have it yet), or some “target” field?

3. How does the provider derive the target sessionKey when the client has not yet learned it?
   - The spec forbids constructing DM session keys (N6) and forbids stream tokens (N7). If the client is missing the DM sessionKey, what minimal identifying info is permitted to request resolution (userId + dmScope mode + provider channel)?

4. Are session keys returned as part of auth_result stable across reconnects and restarts?
   - If dmScope changes at runtime, does the provider push an update (spec mentions “send session_info on role changes” elsewhere in the project), or must the client re-auth?

### 2) Clawline delivery target format boundaries

5. The spec says Clawline `OriginatingTo` format is `<userId>:<streamSuffix>` (e.g., `flynn:main|dm|global`).
   - Where is this format formally defined for code to share (client + provider + extension)?
   - What is the authoritative parser/validator? (Avoid reintroducing ad-hoc string splits.)

6. What are the exact three Clawline stream suffixes and their semantics?
   - `:main` (admin channel?), `:dm` (personal), `:global` (global DM / operator session) are named, but which one corresponds to which UI surface when `dmScope=main`?

7. For dmScope=main: DM session == `agent:main:main`.
   - What `OriginatingTo` should be used for messages that land in `agent:main:main` from a non-admin user?
   - The spec says non-admins must be blocked from DM-targeted messages when dmScope=main (N8), but it doesn’t spell out the exact gate and the error semantics on-wire.

8. For outbound delivery: core sets `deliveryContext.channel` + `deliveryContext.to`.
   - Clawline must “parse suffix for authorization, not routing” (N5). Concretely: what condition is used to decide whether to deliver a given outbound message to a given connected socket?
   - Is it solely based on “socket belongs to userId + admin flag + dmScope mode + suffix”, or is deviceId involved?

9. For outbound message identity, the spec requires messages sent to the client be tagged by `sessionKey` (N7).
   - If core outbound arrives with `deliveryContext.to = flynn:dm`, what exact sessionKey must be attached to the client payload?
     - Is it always `agent:main:clawline:flynn:main` for personal, `agent:main:main` for global, etc.?
   - Where does this mapping live (provider vs extension)?

10. The spec says “each surface maps to a deterministic session key resolved by the core.”
    - For the admin stream vs personal stream, are both session keys in Clawline namespace (`agent:main:clawline:flynn:main`) or is admin always `agent:main:main`?
    - The examples include `agent:main:clawline:flynn:main` described as “Flynn’s Main stream on Clawline” and also describe `agent:main:main` as “Global DM”. We need a definitive mapping table.

### 3) recordInboundSession + session store requirements

11. The spec says “Always call recordInboundSession” (N2).
    - Confirm required call placement relative to message persistence and before dispatching to the agent.
    - If persistence fails (SQLite write fails), should we still call recordInboundSession (core store) or abort? (Avoid the orphan-session class of failures.)

12. recordInboundSession performs two behaviors:
    - per-session meta upsert (for the session the message lands in)
    - optional cross-session updateLastRoute (usually `agent:main:main`)
    The spec alludes to this but doesn’t explicitly list the exact `updateLastRoute` session key for each stream.

13. The spec claims the implicit write in `initSessionState` writes `OriginatingTo` to `lastTo` unconditionally.
    - This is true in core, but implementers need to know the consequence: every Clawline session’s `lastTo` will be overwritten every inbound.
    - Is that desired for channel-scoped sessions like `agent:main:clawline:flynn:main`? (Probably yes, but it should be called out as a deliberate property.)

### 4) lastTo / announce routing interactions

14. Sub-agent announce routing uses `requesterSessionKey` + `requesterOrigin`.
    - Which fields are required on the parent session entry for announce to route back correctly?
    - Is `OriginatingChannel/OriginatingTo` sufficient, or does the announce pipeline also require `deliveryContext` to be present and normalized?

15. The spec says orphan sessions happened when core had no session entry for Clawline sessions.
    - What’s the exact failure path when session entry is missing?
    - Should we add an invariant check in provider logs: after recordInboundSession, verify session store contains the entry?

### 5) Multi-device and per-device behavior

16. How does deviceId interact with delivery?
    - Clawline has per-device sockets; the spec focuses on per-user streams.
    - If user is logged in on two devices, does outbound go to both devices for the same user stream?
    - If yes, should both devices write the same OriginatingTo value (flynn:dm) and thus fight over `lastTo` ordering? Is that acceptable?

17. If a device is non-admin but the same user has an admin device, how are admin-only streams delivered?
    - Authorization says parse suffix for authorization (N5). Do we allow sending admin stream to only admin devices? What if the user switches devices?

### 6) Error semantics and observability

18. What exact error codes/messages should the provider emit for the negative invariants?
    - N8 block: non-admin tries DM when dmScope=main.
    - Invalid/unknown sessionKey.
    - Missing session info / provisioning mismatch.

19. What logging fields are required to debug misroutes?
    - Spec mentions prior investigations; for implementation we need a standard structured log line containing: inbound sessionKey, OriginatingTo, resolved delivery target, admin flag, dmScope mode, and outbound sessionKey selection.

### 7) Mapping table needed

20. The spec would be easier to implement if it had a single explicit mapping table for Clawline:
    - UI surface: Admin Main / Personal DM / Global DM
    - sessionKey (resolved by core) used for that surface
    - OriginatingTo value used on inbound for that surface
    - updateLastRoute target sessionKey + to value (if any) used on inbound
    - Outbound: given deliveryContext.to suffix, which sessionKey is attached to client payload

Right now those pieces are present but spread across sections; implementers will otherwise re-derive (and potentially diverge) when coding.
