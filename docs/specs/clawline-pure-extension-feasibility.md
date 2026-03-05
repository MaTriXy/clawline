# Clawline Pure-Extension Feasibility

## Executive Summary
**Verdict:** **Yes, feasible** to make Clawline a 100% OpenClaw extension, but **not flip-ready today** without finishing a bounded extraction/migration.

**Confidence:** **0.79 (medium-high)** based on current OpenClaw plugin APIs and current Clawline requirements.

**Why:** OpenClaw now has strong extension primitives (service lifecycle, channel runtime helpers, plugin HTTP routing, gateway method registration), but Clawline still depends on explicit core carveouts (`src/clawline/*` plus Clawline-specific plugin-sdk exports). Parity is achievable with a phased migration that keeps session-key invariants and mobile protocol behavior stable.

---

## 1) Yes/No + Confidence
- **Answer:** **YES (feasible)**
- **Confidence:** **0.79**
- **Scope caveat:** Current state is **hybrid** (extension wrapper + core Clawline engine), not pure extension yet.

---

## 2) Exact Core Gaps Still Blocking Pure-Extension Parity

### Gap A: Clawline runtime lives in core, not extension
- Core service bootstrap is still in OpenClaw core:
  - `/Users/mike/src/clawdbot/src/clawline/service.ts:18`
- Core provider server implementation is still in OpenClaw core:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1`
- The extension starts that core service instead of owning its own engine:
  - `/Users/mike/src/clawdbot/extensions/clawline/index.ts:2`
  - `/Users/mike/src/clawdbot/extensions/clawline/index.ts:34`

**Why this blocks pure-extension parity:** Clawline behavior is still implemented in core modules.

### Gap B: Clawline-specific plugin-sdk carveouts remain
- Clawline-specific exports from plugin-sdk:
  - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:451`
  - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:692`
  - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:693`
- Extension depends directly on these carveouts:
  - `/Users/mike/src/clawdbot/extensions/clawline/src/channel.ts:4`
  - `/Users/mike/src/clawdbot/extensions/clawline/src/outbound.ts:3`
  - `/Users/mike/src/clawdbot/extensions/clawline/index.ts:2`

**Why this blocks pure-extension parity:** A pure extension should run on generic plugin APIs, not channel-specific core exports.

### Gap C: Outbound delivery bridge is core-global state
- Global sender singleton is in core:
  - `/Users/mike/src/clawdbot/src/clawline/outbound.ts:5`
- Core service wires sender at startup/shutdown:
  - `/Users/mike/src/clawdbot/src/clawline/service.ts:44`
  - `/Users/mike/src/clawdbot/src/clawline/service.ts:50`

**Why this blocks pure-extension parity:** Extension outbound depends on a core-owned mutable bridge.

### Gap D: Service context is minimal; no direct runtime helper access
- `registerService` context currently exposes only config/state/logger:
  - `/Users/mike/src/clawdbot/src/plugins/types.ts:224`
  - `/Users/mike/src/clawdbot/src/plugins/types.ts:231`
- Clawline core server currently uses many internal runtime modules directly (reply dispatch/routing/session internals):
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:42`
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:48`
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:54`

**Why this blocks pure-extension parity:** Full externalization either needs (a) substantial Clawline-local rewiring to avoid internal imports, or (b) one small generic runtime/service bridge in core.

---

## 3) What Changed Recently in OpenClaw That Closes Old Gaps

### Closed Gap 1: External channels now get shared runtime helpers
- Changelog: channel runtime exposed for external channel plugins:
  - `/Users/mike/src/clawdbot/CHANGELOG.md:21`
- Type/docs in SDK adapter context:
  - `/Users/mike/src/clawdbot/src/channels/plugins/types.adapters.ts:177`
  - `/Users/mike/src/clawdbot/src/channels/plugins/types.adapters.ts:237`

**Impact:** Big reduction in “must import internal channel modules” pressure for extension channels.

### Closed Gap 2: Plugin HTTP route model is explicit + hardened
- Explicit route registration model in changelog:
  - `/Users/mike/src/clawdbot/CHANGELOG.md:34`
- Route registration enforces auth + ownership:
  - `/Users/mike/src/clawdbot/src/plugins/registry.ts:293`
  - `/Users/mike/src/clawdbot/src/plugins/registry.ts:304`
- Gateway route matching/precedence is centralized and deterministic:
  - `/Users/mike/src/clawdbot/src/gateway/server/plugins-http.ts:46`
  - `/Users/mike/src/clawdbot/src/gateway/server/plugins-http/route-match.ts:42`

**Impact:** Extension-owned provider endpoints are much safer/cleaner than older plugin HTTP patterns.

### Closed Gap 3: Service lifecycle registration is stable in plugin system
- Service registration API:
  - `/Users/mike/src/clawdbot/src/plugins/types.ts:280`
- Service start/stop orchestration:
  - `/Users/mike/src/clawdbot/src/plugins/services.ts:34`

**Impact:** Clawline transport process lifecycle can be extension-owned.

---

## 4) Migration Path (Phases + Risk)

### Phase 0: Contract lock
- Freeze Clawline invariants and parity checks (session-key-only routing, no behavior drift).
- Source of truth:
  - `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md:4`

**Risk:** Low.

### Phase 1: Internal extraction inside extension package
- Move Clawline service/server/outbound internals from `src/clawline/*` into `extensions/clawline/src/runtime/*` while keeping behavior byte-for-byte where possible.
- Keep API surface unchanged for app clients.

**Risk:** Medium (large move). Main risk is protocol regression.

### Phase 2: Replace Clawline-specific SDK dependencies
- Stop using `startClawlineService` / `sendClawlineOutboundMessage` / `ClawlineDeliveryTarget` from plugin-sdk.
- Use extension-local equivalents.

**Risk:** Medium-low.

### Phase 3: Remove core carveouts
- Remove core Clawline exports from plugin-sdk and core `src/clawline/*` startup dependency.
- Ensure extension remains installable/bootable as standard plugin.

**Risk:** Medium (cleanup can uncover hidden coupling).

### Phase 4: Soak and parity validation
- Validate pairing/auth, websocket stability, replay/download/upload, stream ops, admin gating, and session-key routing.
- Include multi-agent routing checks because existing findings show known agent-id assumptions to avoid reintroducing:
  - `/Users/mike/shared-workspace/clawline/specs/multi-agent-clawline-routing.md:7`

**Risk:** Medium.

---

## 5) Minimal Core Changes Required (If Unavoidable)

### Unavoidable cleanup changes
1. Remove Clawline-specific plugin-sdk exports after extension migration:
   - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:451`
   - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:692`
   - `/Users/mike/src/clawdbot/src/plugin-sdk/index.ts:693`
2. Remove core Clawline bootstrap dependency once extension owns lifecycle:
   - `/Users/mike/src/clawdbot/src/clawline/service.ts:18`

### Optional but recommended generic core improvement (to reduce extension complexity)
1. Extend `OpenClawPluginServiceContext` with a **generic runtime handle** (not Clawline-specific) so service-style extensions can use stable runtime helpers without internal imports.
   - Current context is narrow:
     - `/Users/mike/src/clawdbot/src/plugins/types.ts:224`

If this generic improvement is not accepted, migration is still possible, but extension code will need more local adapter/shim logic.

---

## 6) Recommendation: Proceed Now?
- **Recommendation:** **Proceed now with Phase 0-1**, but do **not** claim parity until Phase 3+4 gates pass.
- **Reasoning:** Plugin system maturity now justifies extraction work; remaining blockers are mostly explicit carveout removals and coupling cleanup, not fundamental platform limitations.
- **Go/No-Go gate for execution kickoff:**
  1. Confirm acceptance of phased parity (not big-bang swap).
  2. Confirm whether to add the optional generic service runtime context in core.
  3. Lock parity test matrix before moving files.

---

## Evidence Base Used
- OpenClaw plugin APIs/registry/services/runtime/docs in `/Users/mike/src/clawdbot`
- Current Clawline provider docs in `/Users/mike/src/clawdbot/docs/providers/clawline.md`
- Current Clawline invariants/requirements context in `/Users/mike/shared-workspace/clawline/specs`
