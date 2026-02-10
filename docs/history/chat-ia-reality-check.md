# Chat IA Reality Check (Spec vs Code)

This document cross-references `/Users/mike/shared-workspace/clawline/specs/chat-information-architecture.md` against the actual OpenClaw implementation in:
- `src/auto-reply/reply/session.ts`
- `src/channels/session.ts`
- `src/config/sessions/store.ts`
- `src/clawline/server.ts`
- `src/clawline/routing.ts`

Repo snapshot: current `main` after the Chat IA 3-stream implementation commit.

## Verified Accurate (Matches Code)

### Implicit `OriginatingTo` -> `lastTo` write is unconditional
Spec lines 118-130 claim the implicit write is unconditional via:
- `const lastToRaw = ctx.OriginatingTo || ctx.To || baseEntry?.lastTo;`

Code:
- `src/auto-reply/reply/session.ts:246`

This value is normalized and persisted into the per-session `deliveryContext` + flattened `lastTo/lastChannel` on every inbound processing (no guard).

### `recordInboundSession` only performs explicit `updateLastRoute` when provided
Spec describes `recordInboundSession` calling `updateLastRoute` only when the provider supplies it.

Code:
- `src/channels/session.ts:35-50` (early return when `updateLastRoute` is undefined)
- Explicit write path: `src/config/sessions/store.ts:410+` (`updateLastRoute` persists `deliveryContext` + `lastTo/lastChannel`)

### `recordSessionMetaFromInbound` does not write `deliveryContext` / `lastTo`
Spec states meta recording is separate from delivery routing state.

Code:
- `src/config/sessions/store.ts:381-408` only merges `deriveSessionMetaPatch` (origin, group metadata, etc), not `deliveryContext`.

### Clawline delivery target format is canonicalized and supports 3 suffixes
Spec format: `<userId>:<streamSuffix>` where streamSuffix in `{main,dm,global}`.

Code:
- `src/clawline/routing.ts:23-36` documents suffixes.
- `src/clawline/server.ts:3213-3231` sets `OriginatingTo` from `ClawlineDeliveryTarget.fromParts(session.userId, streamSuffix)`.

## Mismatches / Drift (Spec vs Reality)

### 1) Spec claims a *current code bug* that is already fixed
Spec lines 501-502:
- Claims the provider passes `updateLastRoute.sessionKey = route.sessionKey` instead of `route.mainSessionKey`.

Code:
- `src/clawline/server.ts:3232-3247` sets `updateLastRoute.sessionKey = route.mainSessionKey` when `streamSuffix === "dm" && session.dmScope !== "main"`.

Reality:
- The bug described in the spec is no longer present.

Action on spec:
- Remove or update the warning at spec lines 501-502.

### 2) Spec points to a non-existent/incorrect file for `resolveAgentRoute`
Spec line 497:
- "See `src/session/route.ts` for the full type"

Code reality:
- Clawline imports `resolveAgentRoute` from `src/routing/resolve-route.ts`.

Action on spec:
- Update reference to `src/routing/resolve-route.ts` (and reflect that `accountId` is not optional in the real type).

### 3) N8 admin-only DM (dmScope=main) guard exists only indirectly
Spec lines 505-507 describe a guard for "DM when dmScope=main".

Code:
- `src/clawline/server.ts:3099-3111` intentionally avoids classifying `agent:main:main` as `streamSuffix === "dm"` when `dmScope === "main"`.
- `src/clawline/server.ts:3107-3124` classifies `agent:main:main` as `streamSuffix === "global"` and blocks non-admin.

Reality:
- Non-admin writes to `agent:main:main` are blocked (good).
- The "DM" concept does not exist when `dmScope=main` in the provider; it aliases into `global`.

Spec implication:
- The spec can keep the security requirement (block non-admin), but should note that in the current provider implementation the enforcement is via the `global` guard, not a dedicated `dm` guard.

### 4) Handshake visibility vs. what provider sends (Global/DM keys sent to non-admins)
Spec says Global DM is "only visible to admin users" (lines 264-276) and that non-admins see only Main when `dmScope=main` (lines 280-283).

Provider handshake currently sends all three stream sessionKeys unconditionally:
- `src/clawline/server.ts:761-779` (`buildSessionInfo` always includes `{main,dm,global}`)
- `src/clawline/server.ts:2620-2633` (`auth_result` includes `streams: sessionInfo.streams`)
- `src/clawline/server.ts:819-828` (`session_info` includes `streams: resolved.streams`)

Reality:
- Even non-admin clients receive `streams.global.sessionKey = agent:main:main` and `streams.dm.sessionKey` (which may alias to `agent:main:main` when `dmScope=main`).
- Socket subscription is restricted (provider uses `subscribedSessionKeys` to decide outbound delivery), but the *manifest itself* is not filtered.

Why this matters:
- The spec also says the chat list can be derived from the connect manifest. If the client follows that literally, it will show chats it should not.

Action on spec (document expectation explicitly):
- Either:
  - The provider must filter `streams` in the handshake by `isAdmin` and `dmScope` (and dedupe aliases), OR
  - The spec must state that the manifest is not the visibility contract; client must apply visibility rules using `isAdmin` + `dmScope` and dedupe identical session keys.

### 5) Outbound channel filtering is described as provider responsibility, but is mostly enforced by core dispatch
Spec discusses skipping outbound when `deliveryContext.channel !== "clawline"`.

Reality:
- The provider’s `sendOutboundMessage` is invoked via the Clawline channel adapter/tool, i.e. core should only call it when `deliveryContext.channel === "clawline"`.
- There is no explicit `deliveryContext.channel` check inside `src/clawline/server.ts`’s outbound entrypoint.

Action on spec:
- Clarify which layer enforces this (core adapter dispatch vs provider-internal check). If you want defense-in-depth, spec can recommend a provider-side check but should not describe it as already present.

### 6) Global DM explicit `updateLastRoute` write is not implemented (but is also unnecessary)
Spec shows (in some pseudo-code sections) `updateLastRoute` for Global DM.

Reality:
- `src/clawline/server.ts:3232-3241` only sets `updateLastRoute` for `streamSuffix === "dm" && dmScope !== "main"`.
- For Global DM, messages land in `agent:main:main`, so the implicit `OriginatingTo -> lastTo` write (core) updates the same session anyway.

Action on spec:
- Mark explicit `updateLastRoute` for Global DM as optional/unnecessary (implicit write already updates the correct session).

## Notes / Spec Housekeeping

- The spec section "What does the connect handshake look like?" currently labels the handshake as an open question, but the implementation now emits `features:["session_info"]`, plus `auth_result` and `session_info` payloads carrying `{dmScope, streams}`. The spec should either:
  - Update the handshake section to match the implemented payload shapes, or
  - Move handshake definition to the answers doc and treat the spec as conceptual.

