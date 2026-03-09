# Surf Ace Lessons Learned

## Purpose
This document consolidates lessons from Surf Ace ancillary retros/spec supplements/test plans so Surf Ace v2 can be designed without reopening the same failure modes.

## Source Corpus Covered
- `docs/retros/*surf*ace*` and `docs/retros/*transition-surface*`
- `docs/specs/*surf*ace*` except `docs/specs/surf-ace.md`
- `docs/specs/per-stream-transition-surface-contract.md`
- `scratch/docs-drift/docs/*surf*ace*`

The scratch corpus mostly duplicated repo docs; unique findings were consolidated once.

## Theme 1: Architecture Decisions That Prevented Rework

### 1. Define topology first, then protocol
Repeated blocking findings came from unresolved network topology assumptions:
- "CLU talks directly to screens" was not physically true for the iOS path.
- Separate Surf Ace app decisions invalidated earlier implementation sections that assumed in-app ownership.
- Relay vs tunnel semantics were mixed, causing battery/perf/security assumptions to conflict.

v2 rule:
- Publish a single topology contract up front (direct, relay, tunnel), including transport ownership, lifecycle ownership, and reconnect authority.
- Every protocol section must declare which node owns that behavior.

### 2. Keep Surf Ace as a standalone boundary
Feasibility audits converged on: standalone extension is viable and lower-risk than deep Clawline coupling.
What enabled this:
- Service-style background manager in extension.
- Tool registration independent of channel plugin lifecycle.
- Runtime alert primitive (`enqueueSystemEvent` + heartbeat nudge) as a narrow integration seam.

v2 rule:
- Preserve a strict plugin boundary with minimal host hooks.
- If a host API is needed, add a tiny generic SDK primitive rather than importing host internals.

### 3. Do not use Canvas as core control-plane kernel
Canvas analysis was consistent: usable as bootstrap renderer, not as Surf Ace system kernel.
Risks observed:
- Weak source-of-truth boundaries.
- Poor fit for multi-surface orchestration.
- Growing protocol debt when mapping Surf Ace semantics onto generic canvas calls.

v2 rule:
- Keep Surf Ace protocol/state model first-class.
- Treat rendering engines (Canvas/WebView/etc.) as pluggable adapters, not ownership roots.

## Theme 2: Protocol Modeling Lessons

### 1. Schema/prose drift is the highest recurring failure mode
Most review passes found contradictions between prose and JSON schemas (required fields, event sets, scope notes, defaults).
Common drift classes:
- Field exists in prose but not schema (`paneId`, `autoLabel`, etc.).
- Schema allows values prose forbids (or vice versa).
- Defaults written in prose but not encoded in schema.

v2 rule:
- Introduce schema-prose parity gates in CI: each normative field/default/scope must exist in both layers.
- No "normative in appendix only" behavior.

### 2. Naming consistency must be enforced globally
Repeated regressions came from inconsistent payload naming (`w/h` vs `width/height`, content-layer vs tool-layer names).

v2 rule:
- One canonical naming table for wire payload, surface register, and tool responses.
- Any renamed/mapped field requires explicit mapping notes at each boundary.

### 3. Scope every event/content combination explicitly
A recurring bug class was missing scope constraints (for example navigation events on non-HTML content).

v2 rule:
- For each event, define allowed content types, invalid combinations, and required discard behavior.
- Avoid implied scope.

### 4. Nullability and omission semantics must be explicit
Many ambiguities came from unspecified behavior for non-applicable fields (`anchorStart/anchorEnd`, timestamps, optional IDs).

v2 rule:
- Every optional field must define one of: omitted, null, or empty; and when each is used.

## Theme 3: State, Async Boundaries, and Mutation Seams

### 1. Session/stream key must be captured before every async yield
Transition-surface audits showed the same root problem repeatedly: async callbacks reading mutable shim state without session binding.
Impact:
- Wrong-session writes.
- Cross-stream UI corruption.
- Narrow but real race windows that survived multiple patch rounds.

v2 rule:
- Universal async guard contract: capture epoch/session token before yielding; validate token before every post-yield read/write.
- Treat unguarded shim reads after yield as a spec violation.

### 2. Per-stream caches and cursor maps must be truly per-stream
Several findings showed controller-level caches being partially per-stream and partially global.
Impact was usually "self-healing but wrong," which made issues easy to miss.

v2 rule:
- Any state keyed by stream/session must include full key in storage and invalidation path.
- No mixed global+per-stream ownership for the same concept.

### 3. One mutation seam per product concept
Where multiple call sites mutated the same UI/process state directly, regressions recurred.

v2 rule:
- Define a single transition API for each concept (content register, indicator visibility, replay cursor, annotation lifecycle).
- Ban direct writes outside the transition seam.

## Theme 4: Reconnect, Ordering, and Reliability

### 1. Reconnect ordering cannot be implicit
Multiple passes flagged under-specified ordering (`after_reconnect`, snapshot/get replay ordering, event drain timing).

v2 rule:
- Publish a canonical reconnect timeline with strict ordering points and allowed interleavings.
- Include behavior for in-flight snapshot/event overlap.

### 2. Ghost-session handling must be first-class
Busy/takeover behavior and ghost sockets were repeatedly underdefined.

v2 rule:
- Define ghost detection + takeover retry policy explicitly.
- Specify when `paired/busy` reflects active socket vs grace window.

### 3. Heartbeat behavior must be deterministic under load
Heartbeat priority, nonce bounds, and flush-gate initialization were common pain points.

v2 rule:
- Define heartbeat scheduling priority relative to rendering/flush work.
- Specify nonce constraints and startup baseline values.

## Theme 5: Security and Trust Boundaries

### 1. Auto-connect requires mutual auth, not just convenience pairing
Adversarial reviews repeatedly flagged unauthenticated auto-connect as blocking.

v2 rule:
- Require trust bootstrap and mutual verification (cert fingerprint or equivalent keyed trust model).
- Document first-pair trust ceremony and failure behavior.

### 2. Discovery identity length and collision risk matter
Short fingerprint formats were flagged as brute-force/collision-prone.

v2 rule:
- Use collision-resistant published identity fragments and document exact derivation.

### 3. Busy/occupancy payloads can leak user context
Returning occupant-identifying fields without clear policy created privacy and implementation conflicts.

v2 rule:
- Classify discovery and busy fields by privacy sensitivity and define minimum disclosure defaults.

## Theme 6: What Worked

- Iterative adversarial reviews with narrow pass goals surfaced contradictions early.
- Final-gate passes after each fix batch prevented latent cross-section drift.
- Splitting "real issues" from "nits" improved prioritization.
- Reconciliation passes across iOS and Electron test suites reduced platform-specific blind spots.
- Static feasibility audits prevented unnecessary core patches and confirmed extension-local implementations.

## Theme 7: What Did Not Work

- Leaving "decision required" text in normative sections too long blocked implementation readiness.
- Mixing historical status notes/timestamps into normative text increased drift and confusion.
- Oversized test suites included provider concerns in surface-level gates, causing false blockers.
- Ambiguous terminology (session/tab/pane naming) produced incompatible implementations.
- Incremental fixes without explicit ownership contracts reintroduced the same class of race conditions.

## Theme 8: Operational Gotchas for Surf Ace v2

- Treat schema/prose mismatch as blocking, even if behavior seems obvious.
- Distinguish wire guarantees from tool-layer shaping; never rely on implicit mapping.
- Keep event audits complete whenever event enums change.
- Avoid dead cross-references to external tracking docs for normative behavior.
- Tag unresolved items as non-normative appendices until resolved.
- Keep test cases black-box unless instrumentation contracts are explicitly specified.
- If a value is phase-gated or deferred, state exactly what still applies in current phase.

## Surf Ace v2 Build Checklist (Actionable)

1. Freeze topology and connection ownership before protocol edits.
2. Define trust model for pair/auto-connect with explicit first-pair ceremony.
3. Publish canonical payload naming map (wire/register/tools).
4. Enforce schema-prose parity checks in CI.
5. Define event scope matrix (event x contentType) including discard behavior.
6. Specify reconnect timeline with ordering guarantees and overlap handling.
7. Encode ghost-session/takeover rules and grace semantics in one section.
8. Mandate async epoch/session guards in all deferred callbacks.
9. Enforce per-stream ownership for caches/cursors/indicator state.
10. Keep one mutation seam per concept; document owners.
11. Separate surface tests from provider integration tests.
12. Mark spec-open tests explicitly; do not hide ambiguity behind broad OR assertions.
13. Keep normative spec free of historical resolution chatter.
14. Re-run adversarial consistency pass after every major section edit.
15. Ship with a "cross-platform conformance" gate (iOS + Electron behavior parity checks).

## Bottom Line
Surf Ace progress accelerated when boundaries were explicit: topology boundary, state-ownership boundary, and schema/prose boundary. Most expensive regressions came from violating one of those three. Surf Ace v2 should optimize for those boundaries first, then feature breadth.
