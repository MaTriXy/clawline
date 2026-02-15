# MessageInputBar Refactor Spec

## Goal
Refactor chat input UI architecture so that:

1. Input field chrome (background, border, tint, placeholder behavior) has a single source of truth.
2. Connection state can only affect the send button UI, and cannot affect input chrome by construction.
3. The current behavior and visual intent from T069 remain intact for send-button state affordances and animations.

## Current Problems
Observed from recent regressions and fixes:

1. Styling responsibility is split across multiple layers (`ChatView` wiring, `MessageInputBar` internals, platform conditionals), which makes side effects hard to track.
2. Conditional modifiers and platform branches (`#if os(...)`) are interleaved in one large view body, making it easy to accidentally reintroduce off-spec behavior.
3. Connection-related behavior and input editor rendering are composed in the same component, increasing coupling risk.
4. Input placeholder/text surface and chrome behavior were historically not isolated, allowing regressions against spec non-goals.

Summary: this is not unsalvageable logic, but it is high-friction UI composition with too many style decision points.

## Non-Goals
1. No behavior change to message send pipeline, retries, reconnect scheduling, or toast policy.
2. No redesign of theme tokens outside input bar scope.
3. No broad chat-screen architectural rewrite.
4. No branch/worktree/process changes; this is a code-structure refactor only.

## Proposed Architecture

### 1) `MessageInputChromeStyle` (single source of truth)
Create a dedicated style model/provider for editor chrome only.

Responsibilities:
1. Input container fill/material.
2. Optional border/stroke definition.
3. Editor text color/tint color.
4. Opacity treatment when sending.
5. Platform-specific style implementation hidden behind a small API.

Inputs allowed:
1. Platform (`iOS` / `visionOS`).
2. Appearance mode.
3. Is sending / interactive state.
4. Density/size traits as needed.

Inputs explicitly forbidden:
1. Connection state (`SendButtonConnectionState` or transport state).
2. Error code/message strings.

Enforcement:
1. API should not accept connection-state parameters.
2. `MessageEditorChrome` should not import or reference connection state.

### 2) Split `MessageInputBar` into composable subviews

#### `MessageEditorChrome`
Owns only:
1. Rich text editor content binding.
2. Editor container shape/layout.
3. Chrome style application via `MessageInputChromeStyle`.
4. Focus callbacks and editor sizing.

Must not own:
1. Send/reconnect icon state.
2. Connection-state branching.

#### `MessageSendControl`
Owns only:
1. Send/cancel/reconnect tap behavior.
2. Icon-dot morph transitions and required animations.
3. Connection-state accessibility labels.

May depend on:
1. `SendButtonConnectionState`
2. `isSending`, `canSend`

Must not mutate:
1. Editor tint/border/background/placeholder behavior.

#### `MessageInputBar` (container)
Owns composition only:
1. Layout of add button + editor chrome + send control.
2. Pass-through callback wiring from parent.
3. No business logic beyond composition-level guards.

### 3) Type Boundary Enforcement
1. Keep connection state as a dependency of `MessageSendControl` only.
2. Keep editor style dependencies in `MessageInputChromeStyle` only.
3. Introduce lightweight assertions/tests to ensure editor style has no connection-state path.
4. Remove placeholder API surface from `MessageInputBar` if not needed by spec.

### 4) Platform Conditional Consolidation
1. Move platform-specific style branching into style provider methods, not inline in view body.
2. Keep `#if os(...)` near style construction, not scattered through render tree.
3. Preserve existing intentional visionOS differences (if any) while keeping connection-state isolation invariant.

## Migration Path

### Phase 1: Structural extraction (no behavior changes intended)
1. Introduce `MessageInputChromeStyle`.
2. Extract `MessageEditorChrome` with existing editor behavior.
3. Extract `MessageSendControl` with current send-button behavior and animations.
4. Keep `MessageInputBar` API stable where possible to minimize call-site churn.

### Phase 2: Boundary hardening
1. Remove any editor-related params that allow non-user text/status injection in input region.
2. Ensure connection state is passed only to `MessageSendControl`.
3. Remove leftover connection/error style helpers from editor path.

### Phase 3: Verification and cleanup
1. Add/adjust tests described below.
2. Remove dead code and now-unused style helpers.
3. Confirm no off-spec surfaces remain (input border tint, inline error text, banner fallback).

## What Changes
1. Internal structure of `MessageInputBar` into smaller components.
2. Dedicated style object for editor chrome.
3. Centralized platform-specific style logic.
4. Explicit type boundaries preventing connection state from influencing editor chrome.

## What Does Not Change
1. Send-button connection state behavior/semantics from T069.
2. Reconnect/send/cancel action contract exposed to parent.
3. `ChatViewModel` transport/reconnect logic.
4. Input content model and send pipeline.

## Invariants (Must Hold)
1. Connection state UI is represented only in send button affordance.
2. Input chrome does not change for disconnected/failed/reconnecting states.
3. No inline warning/error text appears inside input editor due to connection state.
4. No connection-state-driven border tinting in input field.
5. Send-button animations (dot/icon morph + pulse where specified) continue to run per spec.
6. Editor remains functional across keyboard/focus recreation constraints documented in `MessageInputBar`.

## Test Strategy

### Unit/Logic tests
1. Verify `MessageInputChromeStyle` output does not require or consume connection state.
2. Verify `sendButtonConnectionState` mapping remains unchanged in `ChatViewModel`.

### View-level tests (snapshot or deterministic rendering checks)
1. Input chrome snapshot is identical across connection states (connected/reconnecting/disconnected/failed).
2. Send control snapshots differ appropriately by connection state.
3. No placeholder/error status text in input region when connection changes.

### Interaction tests
1. Disconnected send control tap triggers reconnect callback immediately.
2. Reconnecting state disables hit testing as specified.
3. Cancel action available only in sending state.

### Regression tests
1. Explicit test for GitHub #86 condition: no input border color shift on connection error.
2. Explicit test for T069 non-goals: no inline error text in input.

## Adversarial Self-Review

### Attempted breakpoints and risks
1. Hidden style coupling through environment:
   - Risk: `ColorScheme`/global tint could still indirectly change editor chrome.
   - Mitigation: style provider outputs explicit colors/materials for editor chrome.
2. Platform branches drift:
   - Risk: iOS and visionOS style paths diverge and regress differently.
   - Mitigation: single style provider interface with platform-specific constructors and paired tests.
3. Callback wiring regressions during extraction:
   - Risk: focus/send/paste callbacks break due to subview split.
   - Mitigation: keep callback signatures unchanged in phase 1; add interaction tests.
4. Animation regressions:
   - Risk: moving send control breaks smooth icon/dot morph timing.
   - Mitigation: preserve animation modifiers and state variables inside `MessageSendControl`; add animation-state assertions where feasible.
5. Keyboard recreation behavior:
   - Risk: moving state around reintroduces reset/focus bugs in safe-area inset context.
   - Mitigation: keep parent-owned focus/keyboard state contract; avoid new local persistence state in subviews.
6. False sense of safety from type boundaries:
   - Risk: future dev adds connection state to chrome style “just for one case.”
   - Mitigation: codify invariant in comments + tests; reject PRs violating boundary.

### What could still go wrong
1. Visual parity drift if style constants are copied incorrectly during extraction.
2. Accessibility labels/hints may regress if send-control logic is moved without parity checks.
3. Test coverage might miss runtime-only animation smoothness seen on device.

### What this proposal may still miss
1. It does not simplify all of `ChatView` composition complexity; only input bar boundaries.
2. It does not solve broader chat-screen state ownership issues unrelated to input chrome.
3. It assumes existing `RichTextEditor` behavior is stable; if editor internals inject placeholder/status text, that requires separate enforcement in editor layer.

## Acceptance Criteria
1. `MessageInputBar` is split into editor and send-control subcomponents.
2. Editor style is driven by `MessageInputChromeStyle` and has no connection-state dependency.
3. Device verification: disconnect/reconnect/failure never changes input border/tint/placeholder/status text.
4. Device verification: send button shows required T069 states and animations.
5. Regression tests added and passing for #86/T069 input non-goals.
