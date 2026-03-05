# T141 Clawline Extension Isolation

**Status:** Draft
**Date:** 2026-03-05
**Parent:** [clawline-pure-extension-feasibility.md](./clawline-pure-extension-feasibility.md)
**Scope:** Gaps A, B, C from the feasibility report (pure Clawline-side; no core contribution required)
**Out of scope:** Gap D (service context / runtime helper access)

---

## 1. Goal

Make the Clawline extension the single owner of Clawline's lifecycle, configuration, outbound delivery, and public types. After this work:

- The extension starts, configures, and stops the Clawline provider engine directly.
- No Clawline-specific exports remain in `src/plugin-sdk/index.ts`.
- Outbound delivery is extension-local state, not core global state.
- `src/clawline/` is reduced to a runtime engine consumed by the extension via a clean, typed interface.

The runtime engine (server.ts and its heavy-dependency files) stays in `src/clawline/` until Gap D is resolved. This is intentional: the engine imports ~25 core internal modules (auto-reply, agents, gateway, infra, media) that cannot be routed through the plugin-sdk today. The isolation work in this spec maximizes what can move NOW without that bridge.

---

## 2. Architecture

### 2.1 Current state

```
extensions/clawline/index.ts
  ──import──> openclaw/plugin-sdk (startClawlineService, ClawlineDeliveryTarget, sendClawlineOutboundMessage)
                ──re-export──> src/clawline/service.ts (startClawlineService)
                                 ──calls──> src/clawline/server.ts (createProviderServer)
                                 ──wires──> src/clawline/outbound.ts (global sender singleton)
                ──re-export──> src/clawline/routing.ts (ClawlineDeliveryTarget)
                ──re-export──> src/clawline/outbound.ts (sendClawlineOutboundMessage)
```

Problems:
- Extension delegates ALL lifecycle to a core function (`startClawlineService`).
- Extension depends on 3 Clawline-specific plugin-sdk carveouts.
- Outbound delivery uses a core-owned mutable global singleton.

### 2.2 Target state

```
extensions/clawline/index.ts
  ──owns──> extensions/clawline/src/runtime/outbound.ts (extension-local sender singleton)
  ──owns──> extensions/clawline/src/runtime/routing.ts  (ClawlineDeliveryTarget, extension-local copy)
  ──owns──> extensions/clawline/src/runtime/config.ts   (resolveClawlineConfig, extension-local)
  ──imports──> src/clawline/server.ts (createProviderServer) via explicit internal path
  ──imports──> src/clawline/domain.ts (types) via explicit internal path

plugin-sdk/index.ts: zero Clawline exports
src/clawline/outbound.ts: deleted
src/clawline/service.ts: deleted
src/clawline/config.ts: deleted (moved to extension)
src/clawline/routing.ts: retained (server.ts uses it) but no longer SDK-exported
```

### 2.3 Engine interface contract

After isolation, the extension's boundary with core is a typed interface on the engine:

```typescript
// src/clawline/server.ts — public entry point
export async function createProviderServer(options: ProviderOptions): Promise<ProviderServer>;

// src/clawline/domain.ts — shared types
export type ProviderOptions = { ... };
export interface ProviderServer {
  start(): Promise<void>;
  stop(): Promise<void>;
  getPort(): number;
  sendMessage(params: ClawlineOutboundSendParams): Promise<ClawlineOutboundSendResult>;
  getSurfAceRuntime?(): SurfAceRuntime | null;
}
```

The extension imports `createProviderServer` and the needed types. No other core Clawline modules are imported by the extension.

---

## 3. Invariants (must hold at every phase boundary)

These are non-negotiable. Any phase that breaks an invariant is rolled back.

### 3.1 Session-key routing

Per [clawline-invariants.md](./clawline-invariants.md) invariant #1:

- Session keys are the only routing identifiers.
- Admin channel: `agent:main:main`
- Personal channel: `agent:main:clawline:{userId}:main`
- Custom streams: `agent:main:clawline:{userId}:s_{8hex}`
- `ClawlineDeliveryTarget` format: `{userId}:{sessionLabel}` (NOT a session key)

Session key construction, parsing, and storage must produce identical output before and after each phase.

### 3.2 Mobile protocol stability

- WebSocket protocol version (`PROTOCOL_VERSION = 1`) unchanged.
- Pairing flow (pending request → approval → JWT issuance) byte-compatible.
- Stream snapshot/create/update/delete server messages unchanged.
- Asset upload/download HTTP endpoints unchanged.
- Auth headers and JWT claims unchanged.

### 3.3 Outbound delivery contract

- `sendMessage({target, text, attachments?})` produces the same `{messageId, userId, deviceId, assetIds?}` result.
- Calling `sendClawlineOutboundMessage` or the local equivalent when the service is not running throws with the same error message.
- The `clawlineOutbound` adapter in `extensions/clawline/src/outbound.ts` continues to resolve targets identically.

### 3.4 Config resolution

- `resolveClawlineConfig(openClawConfig)` returns identical `ResolvedClawlineConfig` values.
- Default paths (`~/.openclaw/clawline`, `~/.openclaw/clawline-media`), port (18800), network bind (127.0.0.1) unchanged.

---

## 4. Migration Phases

### Phase 0: Contract lock (prerequisite)

**Goal:** Establish the parity test matrix before moving any code.

**Work:**
1. Enumerate all behaviors that must be tested at phase boundaries. At minimum:
   - Pairing a new device (pending → approved → JWT issued)
   - WebSocket connect with valid JWT, receive stream snapshot
   - Send user message on admin channel → session key `agent:main:main`
   - Send user message on personal channel → session key `agent:main:clawline:{userId}:main`
   - Create/rename/delete custom stream
   - Outbound text delivery via `sendClawlineOutboundMessage`
   - Outbound media delivery (attachment with base64 data)
   - Asset upload (POST /api/assets) and download (GET /api/assets/:id)
   - Message replay on reconnect
   - Channel action: `channel-list`, `channel-create`, `channel-edit`, `channel-delete`
   - `clawline_dm` tool invocation (via `clawlineOutbound.sendText`)
   - Config reload with `channels.clawline.*` changes
   - SurfAce discovery (if available)
2. Capture baseline output for each test (session keys, message IDs, error messages).
3. Document in a parity checklist file at `shared-workspace/clawline/specs/clawline-isolation-parity.md`.

**Risk:** Low. No code changes.

---

### Phase 1: Outbound bridge migration (Gap C)

**Goal:** Move outbound delivery ownership from core global state to extension-local state.

**What changes:**

| File | Action | Notes |
|---|---|---|
| `extensions/clawline/src/runtime/outbound.ts` | **Create** | Extension-local sender singleton. Same API shape as current `src/clawline/outbound.ts`. |
| `extensions/clawline/index.ts` | **Edit** | Wire sender in service `start` using `server.sendMessage`; clear in `stop`. Import from local runtime, not SDK. |
| `extensions/clawline/src/outbound.ts` | **Edit** | Import `sendClawlineOutboundMessage` from `../runtime/outbound.ts` instead of `openclaw/plugin-sdk`. |
| `extensions/clawline/src/actions.ts` | **Edit** | Import `sendClawlineOutboundMessage` from `../runtime/outbound.ts` instead of `openclaw/plugin-sdk`. |
| `src/clawline/service.ts` | **Edit** | Remove `setClawlineOutboundSender` calls (the extension now owns this). Service just creates/starts/stops the server. |
| `src/plugin-sdk/index.ts:692` | **Edit** | Remove `sendClawlineOutboundMessage` re-export. |

**Extension-local outbound module:**

```typescript
// extensions/clawline/src/runtime/outbound.ts
import type { ClawlineOutboundSendParams, ClawlineOutboundSendResult } from "./types.js";

type ClawlineSendFn = (params: ClawlineOutboundSendParams) => Promise<ClawlineOutboundSendResult>;

let currentSender: ClawlineSendFn | null = null;

export function setClawlineSender(sender: ClawlineSendFn | null): void {
  currentSender = sender;
}

export async function sendClawlineOutboundMessage(
  params: ClawlineOutboundSendParams,
): Promise<ClawlineOutboundSendResult> {
  const sender = currentSender;
  if (!sender) {
    throw new Error("clawline outbound delivery is not available (service not running)");
  }
  return await sender(params);
}
```

**Extension index.ts service wiring (after edit):**

```typescript
// In service start:
const server = await createProviderServer({ ... });
await server.start();
setClawlineSender((payload) => server.sendMessage(payload));

// In service stop:
setClawlineSender(null);
await server.stop();
```

**Verification:**
- Outbound text/media delivery produces identical results.
- Calling send before service start throws same error.
- Existing tests in `extensions/clawline/src/actions.test.ts` and `extensions/clawline/src/channel.test.ts` pass.

**Risk:** Medium-low. The outbound singleton is a thin wrapper. Main risk is a consumer still importing the old path; caught at build time.

---

### Phase 2: SDK carveout removal (Gap B)

**Goal:** Remove all 3 Clawline-specific exports from `src/plugin-sdk/index.ts`. Extension uses its own copies.

**Depends on:** Phase 1 (sendClawlineOutboundMessage export already removed).

**What changes:**

| File | Action | Notes |
|---|---|---|
| `extensions/clawline/src/runtime/routing.ts` | **Create** | Copy of `ClawlineDeliveryTarget` class from `src/clawline/routing.ts`. Identical implementation. |
| `extensions/clawline/src/channel.ts:4` | **Edit** | Import `ClawlineDeliveryTarget` from `../runtime/routing.ts` instead of `openclaw/plugin-sdk`. |
| `src/plugin-sdk/index.ts:451` | **Edit** | Remove `ClawlineDeliveryTarget` re-export. |
| `src/plugin-sdk/index.ts:693` | **Edit** | Remove `startClawlineService` / `ClawlineServiceHandle` re-export. |
| `extensions/clawline/index.ts` | **Edit** | Stop importing `startClawlineService` from SDK. Import `createProviderServer` directly (see Phase 3 detail). |

After this phase, `src/plugin-sdk/index.ts` has zero Clawline-specific exports.

**Note on `ClawlineDeliveryTarget` duplication:** Both the extension copy (`extensions/clawline/src/runtime/routing.ts`) and the core copy (`src/clawline/routing.ts`) will exist simultaneously. This is intentional: server.ts in core still needs its copy, and the extension needs its own. They are value-type classes with no shared mutable state. Duplication is removed when server.ts moves to the extension (Gap D resolution).

**Verification:**
- `pnpm build` succeeds with no Clawline imports from plugin-sdk.
- `ClawlineDeliveryTarget.fromString("flynn:main").toSessionKey()` returns `agent:main:clawline:flynn:main` from both copies.
- All channel.test.ts and actions.test.ts pass.

**Risk:** Medium-low. Compile-time safety catches missed import updates. The duplication of `ClawlineDeliveryTarget` is a conscious trade-off documented in the phase.

---

### Phase 3: Service bootstrap migration (Gap A)

**Goal:** Extension directly owns config resolution and server lifecycle. `src/clawline/service.ts` is deleted.

**Depends on:** Phase 1 (outbound already extension-local), Phase 2 (SDK carveouts removed).

**What changes:**

| File | Action | Notes |
|---|---|---|
| `extensions/clawline/src/runtime/config.ts` | **Create** | Move `resolveClawlineConfig` from `src/clawline/config.ts`. Requires resolving 3 core imports (see below). |
| `extensions/clawline/src/runtime/types.ts` | **Create** | Extension-local type definitions extracted from `src/clawline/domain.ts` (outbound types, config types). |
| `extensions/clawline/index.ts` | **Edit** | Replace `startClawlineService()` call with direct config resolution + `createProviderServer()` call. |
| `src/clawline/service.ts` | **Delete** | Bootstrap logic now lives in the extension. |
| `src/clawline/config.ts` | **Delete** | Config resolution now lives in the extension. |
| `src/clawline/outbound.ts` | **Delete** | Already replaced in Phase 1; this is the cleanup. |

**Config resolution dependency handling:**

`resolveClawlineConfig` in `src/clawline/config.ts` currently imports:
1. `OpenClawConfig` from `../config/config.js` — available via `openclaw/plugin-sdk` (already exported as type)
2. `DEFAULT_AGENT_WORKSPACE_DIR` from `../agents/workspace.js` — small constant, inline or duplicate in extension
3. `resolveUserPath` from `../utils.js` — small utility, inline in extension
4. `ProviderConfig` from `./domain.js` — type moves to extension runtime types
5. `deepMerge` from `./utils/deep-merge.ts` — small pure function, move to extension

For items 2-3, the extension inlines the values directly:
- `DEFAULT_AGENT_WORKSPACE_DIR = path.join(os.homedir(), ".openclaw", "workspace")` (constant)
- `resolveUserPath` is a ~5 line tilde-expansion function

This keeps the extension self-contained without adding new SDK exports.

**Extension service start (after edit):**

```typescript
api.registerService({
  id: "clawline",
  start: async ({ config, logger }) => {
    // Extension owns config resolution
    const resolved = resolveClawlineConfig(config);
    if (!resolved.enabled) return;

    // Extension resolves session parameters
    const mainSessionKey = resolveMainSessionKey(config);  // from SDK
    const sessionStorePath = resolveStorePath(config.session?.store, {
      agentId: resolveAgentIdFromSessionKey(mainSessionKey),
    });

    // Extension creates engine directly
    server = await createProviderServer({
      config: resolved,
      openClawConfig: config,
      logger,
      sessionStorePath,
      mainSessionKey,
    });
    await server.start();

    // Extension owns outbound wiring
    setClawlineSender((payload) => server.sendMessage(payload));
    setClawlineSurfAceRuntime(server.getSurfAceRuntime?.() ?? null);
  },
  stop: async () => {
    setClawlineSender(null);
    setClawlineSurfAceRuntime(null);
    await server?.stop();
    server = null;
  },
});
```

**Import path for `createProviderServer`:**

The extension needs to import `createProviderServer` from `src/clawline/server.ts`. Since the extension is a workspace package that resolves `openclaw` at runtime via jiti, one of these mechanisms is needed:

**Option A (preferred): Direct internal import.**
The extension uses `openclaw/clawline/server` as an import specifier, with an `exports` entry in the root `package.json`:
```json
"./clawline/server": "./src/clawline/server.ts"
```
This is a narrow, typed entry point — not a Clawline-specific SDK carveout. It's a standard package subpath export for internal extension use.

**Option B: Re-export through engine barrel.**
Create `src/clawline/index.ts` that exports only `createProviderServer` and its types. Extension imports from `openclaw/clawline`.

Either option maintains a clean boundary. The extension imports exactly one function and its parameter/return types from core.

**Session helper imports:** `resolveMainSessionKey`, `resolveStorePath`, `resolveAgentIdFromSessionKey` are already available via `openclaw/plugin-sdk` (they're generic session utilities, not Clawline-specific). If not already exported, they are candidates for generic SDK export (not a Clawline carveout).

**Verification:**
- Service starts and stops identically.
- `src/clawline/service.ts` and `src/clawline/config.ts` no longer exist.
- All parity tests pass.
- `extensions/clawline/` is the sole consumer of config resolution.

**Risk:** Medium. This is the largest phase. Risks:
- Session helper availability via SDK (may need to add generic exports — but these are NOT Clawline-specific).
- Config resolution edge cases if inlined constants drift from core originals.

---

### Phase 4: Cleanup and parity validation

**Goal:** Remove dead code, verify full parity, soak.

**What changes:**

| File | Action | Notes |
|---|---|---|
| `src/clawline/outbound.ts` | Verify deleted | Should be gone from Phase 1/3. |
| `src/clawline/service.ts` | Verify deleted | Should be gone from Phase 3. |
| `src/clawline/config.ts` | Verify deleted | Should be gone from Phase 3. |
| `src/plugin-sdk/index.ts` | Verify clean | Zero Clawline exports. |
| Tests | Update | Move/update `src/clawline/config.test.ts` to extension. Delete `src/clawline/service.ts` tests if any. |

**Parity validation matrix** (full pass against Phase 0 baseline):
- [ ] Device pairing (pending → approved → JWT)
- [ ] WebSocket connect + stream snapshot
- [ ] Admin channel message → `agent:main:main`
- [ ] Personal channel message → `agent:main:clawline:{userId}:main`
- [ ] Custom stream create/rename/delete
- [ ] Outbound text delivery
- [ ] Outbound media delivery (base64 attachment)
- [ ] Asset upload + download
- [ ] Message replay on reconnect
- [ ] Channel actions (list/create/edit/delete)
- [ ] clawline_dm tool invocation
- [ ] Config reload
- [ ] SurfAce discovery (if testable)
- [ ] Multi-agent routing: verify no `agent:main` hardcoding reintroduced (per [multi-agent-clawline-routing.md](./multi-agent-clawline-routing.md))

**Risk:** Medium. Cleanup can uncover hidden coupling. The parity matrix is the safety net.

---

## 5. File inventory summary

### Files that move to extension

| Source | Destination | Phase |
|---|---|---|
| `src/clawline/outbound.ts` | `extensions/clawline/src/runtime/outbound.ts` (rewrite) | 1 |
| `src/clawline/routing.ts` | `extensions/clawline/src/runtime/routing.ts` (copy) | 2 |
| `src/clawline/config.ts` | `extensions/clawline/src/runtime/config.ts` (move + adapt) | 3 |
| `src/clawline/utils/deep-merge.ts` | `extensions/clawline/src/runtime/deep-merge.ts` (move) | 3 |
| Outbound/config types from `domain.ts` | `extensions/clawline/src/runtime/types.ts` (extract) | 3 |

### Files deleted from core

| File | Phase | Reason |
|---|---|---|
| `src/clawline/outbound.ts` | 3 (cleanup) | Replaced by extension-local outbound |
| `src/clawline/service.ts` | 3 | Bootstrap logic moved to extension |
| `src/clawline/config.ts` | 3 | Config resolution moved to extension |

### Files remaining in core (`src/clawline/`)

These stay until Gap D (service context / runtime helper access) is resolved:

| File | LOC | Why it stays |
|---|---|---|
| `server.ts` | ~7000 | 25+ core internal imports (auto-reply, agents, gateway, infra, media) |
| `domain.ts` | ~180 | Types used by server.ts |
| `routing.ts` | ~120 | Used by server.ts (extension has its own copy) |
| `errors.ts` | ~19 | Used by server.ts |
| `session-store.ts` | ~70 | Imports `config/sessions` internals |
| `session-key.ts` | ~4 | Used by server.ts |
| `http-assets.ts` | ~large | Used by server.ts |
| `attachments.ts` | ~large | Used by server.ts |
| `surf-ace.ts` | ~large | Imports `process/exec` internal |
| `rate-limiter.ts` | ~small | Used by server.ts |
| `per-user-task-queue.ts` | ~small | Used by server.ts |
| `utils/deep-merge.ts` | ~small | Used by server.ts (extension has its own copy) |

### Plugin-SDK export removal

| Line | Export | Removed in |
|---|---|---|
| `src/plugin-sdk/index.ts:692` | `sendClawlineOutboundMessage` | Phase 1 |
| `src/plugin-sdk/index.ts:451` | `ClawlineDeliveryTarget` | Phase 2 |
| `src/plugin-sdk/index.ts:693` | `startClawlineService`, `ClawlineServiceHandle` | Phase 2 |

---

## 6. Risks and mitigations

### R1: Import path resolution for `createProviderServer`

**Risk:** The extension needs to import from `src/clawline/server.ts`. Workspace extensions resolve `openclaw/plugin-sdk` via jiti alias, but deeper subpath imports may not be configured.

**Mitigation:** Add a single `exports` entry to root `package.json` for `./clawline/server`. Test that import resolution works in dev (bun/jiti) and in installed mode (npm install --omit=dev). If subpath exports don't work, fall back to re-exporting `createProviderServer` through a barrel at `src/clawline/index.ts`.

### R2: Session helper availability in plugin-sdk

**Risk:** Phase 3 needs `resolveMainSessionKey`, `resolveStorePath`, `resolveAgentIdFromSessionKey` available to extensions. These are generic session utilities but may not be exported via plugin-sdk today.

**Mitigation:** Check current plugin-sdk exports before starting Phase 3. If missing, add them as generic exports (they are NOT Clawline-specific — any extension with session awareness needs them). This is a core change but is a generic improvement, not a Clawline carveout.

### R3: `ClawlineDeliveryTarget` duplication drift

**Risk:** Two copies of `ClawlineDeliveryTarget` exist (core and extension) and could drift.

**Mitigation:**
- Both copies have identical, simple logic (~120 LOC, no external deps).
- Add a cross-reference comment in both files pointing to the other.
- Duplication is temporary: resolved when server.ts moves to extension (Gap D).
- If format changes are needed before Gap D, update both copies in the same PR.

### R4: Config resolution constant drift

**Risk:** `DEFAULT_AGENT_WORKSPACE_DIR` or `resolveUserPath` inlined in the extension could drift from core.

**Mitigation:**
- These are stable values (`~/.openclaw/workspace`, tilde expansion). They haven't changed in months.
- Document the inlined values with comments referencing core source.
- If core changes the workspace default, the extension config needs updating. This is caught by parity tests.

### R5: Protocol regression during migration

**Risk:** Subtle behavior change in message routing, session key construction, or outbound delivery.

**Mitigation:** Phase 0 contract lock + Phase 4 parity validation. Every phase boundary runs the full parity checklist.

### R6: Multi-agent routing regression

**Risk:** Per [multi-agent-clawline-routing.md](./multi-agent-clawline-routing.md), iOS hardcodes `agent:main` in session key construction. Migration must not reintroduce hardcoded agent-id assumptions in the extension.

**Mitigation:** Parity test explicitly checks that `resolveAgentIdFromSessionKey` (not a literal) drives agent-id in session keys. Extension config resolution uses config-derived values, never literals.

---

## 7. Gap D handoff notes

When Gap D (service context / runtime helper access) is resolved, the remaining `src/clawline/` files can move into the extension. The required work at that point:

1. Extend `OpenClawPluginServiceContext` with a runtime handle providing access to: reply dispatch, agent identity resolution, session recording, gateway calls, TLS runtime, media processing, SSRF-safe networking.
2. Move `server.ts` and all remaining `src/clawline/` files into `extensions/clawline/src/runtime/`.
3. Rewrite server.ts imports from `../auto-reply/*`, `../agents/*`, `../gateway/*`, `../infra/*`, `../media/*` to use the runtime handle.
4. Delete `src/clawline/` directory entirely.
5. Remove the `./clawline/server` subpath export from root `package.json`.
6. Delete the extension's duplicate `ClawlineDeliveryTarget` (now server.ts and extension are co-located).

This work is substantial (server.ts is ~7000 LOC with deep core coupling) but is cleanly separable from the isolation work in this spec.

---

## 8. Implementation order summary

```
Phase 0  ─────  Contract lock, parity baseline
    │
Phase 1  ─────  Outbound bridge → extension (Gap C)
    │
Phase 2  ─────  SDK carveouts removed (Gap B)
    │
Phase 3  ─────  Service bootstrap → extension (Gap A)
    │
Phase 4  ─────  Cleanup + full parity soak
    │
[Future: Gap D] ── Engine extraction (server.ts → extension)
```

Each phase is independently deployable. If a phase fails parity, it is reverted without affecting earlier phases.
