# Above-Bar Gap Analysis

The gap between the last message bubble and the top of the message input bar is
intermittently too large on first load, then self-corrects after user interaction.
This document traces every code path that affects the gap and identifies the race
conditions responsible.

---

## 1. How the gap is determined

The visible gap between the last bubble's bottom edge and the input bar's top edge
is the result of **two independent layout systems** that must agree:

| System | Controls | Mechanism |
|--------|----------|-----------|
| **Collection view content inset** | Where the last bubble sits (relative to screen bottom) | `collectionView.contentInset.bottom = listBottomInset` |
| **Auto Layout constraints** | Where the input bar sits (relative to screen/keyboard bottom) | `KeyboardPinnedContainer` constraints against `keyboardLayoutGuide` |

The gap equals:

```
gap = (listBottomInset + sectionInset.bottom) − inputBarTopFromScreenBottom
```

If the two systems compute their positions from different snapshots of shared
inputs (`keyboardHeight`, `inputBarHeight`, `safeAreaInsets.bottom`), the gap is
wrong until they re-synchronize.

---

## 2. The formula (ChatView.swift:225-226)

```swift
let listBottomInset = keyboardInset + belowBarGap + resolvedInputHeight
    + metrics.flowGap - metrics.containerPadding
```

### Inputs

| Variable | Source | Initial value | Updated by |
|----------|--------|---------------|------------|
| `keyboardHeight` | `@State` (line 92) | `0` | `KeyboardLayoutGuideObserverView` notification callback |
| `inputBarHeight` | `@State` (line 110) | `0` | `KeyboardPinnedContainer.Coordinator` via `DispatchQueue.main.async` |
| `geometry.safeAreaInsets.bottom` | `GeometryProxy` | system-provided (may be 0 on first frame) | SwiftUI layout pass |
| `horizontalSizeClass` | `@Environment` | system-provided | trait collection change |

### Derived values

| Derived | Expression | Depends on |
|---------|-----------|------------|
| `keyboardVisibleHeight` | `max(0, keyboardHeight − geometry.safeAreaInsets.bottom)` | `keyboardHeight`, `geometry` |
| `isKeyboardVisible` | `keyboardVisibleHeight > 0.5` | `keyboardVisibleHeight` |
| `keyboardInset` | `isKeyboardVisible ? keyboardHeight : 0` | binary switch on `isKeyboardVisible` |
| `belowBarGap` | `isKeyboardVisible ? 12 : 24` | binary switch on `isKeyboardVisible` |
| `resolvedInputHeight` | `max(inputBarHeight, 44)` | `inputBarHeight` |
| `metrics.flowGap` | compact ? 12 : 16 | `horizontalSizeClass` |
| `metrics.containerPadding` | compact ? 12 : 24 | `horizontalSizeClass` |

---

## 3. Race condition 1: `keyboardHeight` updates before `safeAreaInsets.bottom` is valid

**This is the most likely cause of the intermittent too-large gap.**

### The mechanism

`KeyboardLayoutGuideObserverView` (line 813) subscribes to
`keyboardWillChangeFrameNotification`. On iPhone with a home indicator, the
"keyboard hidden" notification reports `endFrame.origin.y` such that:

```
screenHeight − endFrame.origin.y ≈ 34  (the safe area bottom)
```

This is because UIKit considers the input accessory region to extend into the
safe area.

### The race

1. View appears. `keyboardHeight = 0`, `geometry.safeAreaInsets.bottom` = valid (34).
2. `KeyboardLayoutGuideObserverView` is added to the window. A stale or initial
   `keyboardWillChangeFrameNotification` fires.
3. `onHeightChange?(34)` is called. `keyboardHeight` is set to 34.
4. SwiftUI re-evaluates `chatContent`. Two possible outcomes:

   **Outcome A (correct):** `geometry.safeAreaInsets.bottom` is still 34.
   `keyboardVisibleHeight = max(0, 34 − 34) = 0`. `isKeyboardVisible = false`.
   `keyboardInset = 0`. Formula produces the correct result.

   **Outcome B (race):** The GeometryReader hasn't updated yet on this frame
   (e.g., it was invalidated by the `@State` change but hasn't re-measured).
   `geometry.safeAreaInsets.bottom` is stale at `0`.
   `keyboardVisibleHeight = max(0, 34 − 0) = 34`. `isKeyboardVisible = true`.
   `keyboardInset = 34`, `belowBarGap = 12`.

   For compact mode:
   ```
   listBottomInset = 34 + 12 + 44 + 12 − 12 = 90  (should be 68)
   ```

   The gap is inflated by **22pt**.

### Why it self-corrects

On the next layout pass, `geometry.safeAreaInsets.bottom` catches up to 34,
`isKeyboardVisible` flips back to `false`, and the formula returns to 68. Any
user interaction (scroll, tap) triggers a layout pass that applies the corrected
value.

### Why it doesn't always happen

The race depends on exact timing: whether the notification fires on the same
run-loop tick as the GeometryReader evaluation. This varies by device, OS
version, and whether the app is restoring from background.

---

## 4. Race condition 2: `inputBarHeight` async measurement delay

### The mechanism

`KeyboardPinnedContainer.Coordinator.updateConstraints` (line 915) measures the
hosting view height and writes it back to the `inputBarHeight` binding via
**`DispatchQueue.main.async`** (line 1035):

```swift
if container.bounds.width > 0 {
    container.layoutIfNeeded()
    let currentHeight = hostingView.bounds.height
    if abs(measuredHeight.wrappedValue - currentHeight) > 0.5 {
        DispatchQueue.main.async {
            measuredHeight.wrappedValue = currentHeight
        }
    }
}
```

### The race

1. `inputBarHeight` starts at 0.
2. `resolvedInputHeight = max(0, 44) = 44`. The 44pt floor masks the problem for
   single-line input.
3. `KeyboardPinnedContainer.updateUIView` runs. The container has `bounds.width > 0`.
   `layoutIfNeeded()` is called. But the hosting view's constraints may not have
   fully resolved yet (the `keyboardLayoutGuide` anchor positions depend on whether
   the view is in a window and whether the guide has received its first frame).
4. The async dispatch schedules the height update for the next run-loop tick.
5. On the next tick, `inputBarHeight` is set (e.g., to 46). This triggers another
   SwiftUI body evaluation, which recomputes `listBottomInset` with the new
   `resolvedInputHeight = 46`.
6. Meanwhile, the collection view already received the old `listBottomInset`
   computed with `resolvedInputHeight = 44`. There's a one-frame lag.

### Impact on the gap

For single-line input, the 44pt floor means `resolvedInputHeight` is 44 on frame
0 and 44-46 on frame 1 — a delta of only 0-2pt. This is minor.

For multi-line input (e.g., draft text restored on launch), the floor is too low.
`resolvedInputHeight` could jump from 44 to 80+ on the async callback, causing a
sudden inset increase that looks like a gap expansion.

---

## 5. Race condition 3: `isKeyboardVisible` shadowing and dual sources

### The shadowing

There are **two different `isKeyboardVisible` definitions**:

1. **Computed property** (line 113): `keyboardHeight > 0.5` — does NOT subtract
   safe area.
2. **Local let** inside `chatContent` (line 218): `keyboardVisibleHeight > 0.5` —
   DOES subtract safe area.

The local `let` correctly shadows the property within `chatContent`. But:

- The collection view receives `isKeyboardVisible: isInputFocused` (line 341),
  which is the **focus callback**, not either keyboard height check.
- `KeyboardPinnedContainer` receives `isKeyboardVisible` from the local let
  (line 269), which is the **safe-area-adjusted keyboard check**.

These are **different signals with different timing**:

| Signal | Fires when | Latency |
|--------|-----------|---------|
| `isInputFocused` (focus callback) | UITextView becomes first responder | Immediate |
| `isKeyboardVisible` (keyboard height) | Notification from UIKit keyboard system | Delayed by animation start |

### The desynchronization

When the user taps the input field:

1. `textViewDidBeginEditing` fires → `isInputFocused = true`.
2. SwiftUI re-evaluates. Collection view gets `isKeyboardVisible = true` (from
   focus). But `keyboardHeight` is still 0 → `isKeyboardVisible` (local let) is
   `false`.
3. The `KeyboardPinnedContainer` receives `isKeyboardVisible = false` (no keyboard
   yet). It uses the keyboard-hidden constraint chain (version label + gaps).
4. `listBottomInset` is computed with `isKeyboardVisible = false` → `keyboardInset = 0`,
   `belowBarGap = 24`.
5. Keyboard notification arrives → `keyboardHeight` jumps to ~336.
6. Re-evaluation: `isKeyboardVisible = true` → `keyboardInset = 336`,
   `belowBarGap = 12`.
7. `listBottomInset` jumps from 68 to 336+12+44+12-12 = 392.

Between steps 4 and 6, the collection view has `isKeyboardVisible = true` (from
focus) but `bottomInset = 68` (from keyboard-hidden calculation). This means the
collection view thinks the keyboard is up but has the wrong inset — it may
attempt keyboard-related scroll adjustments with stale geometry.

---

## 6. Race condition 4: constraint system initial state in KeyboardPinnedContainer

### The mechanism

`KeyboardPinnedContainerView` sets `keyboardLayoutGuide.usesBottomSafeArea = false`
(line 1078). When the keyboard is hidden, this makes the guide collapse to the
view's **own bottom edge** instead of the safe area bottom.

### The problem

Before the container view is added to a window, the keyboard layout guide is not
fully active. The guide's top anchor position may be indeterminate. The
coordinator's first `updateConstraints` call (triggered by `makeUIView` →
`updateUIView`) runs `container.layoutIfNeeded()` and measures
`hostingView.bounds.height`.

If the guide hasn't resolved yet, the hosting view may be laid out with an
incorrect bottom anchor, producing a wrong height measurement. This wrong height
is written to `inputBarHeight` via the async dispatch.

### Initial constraint activation order

On the first `updateConstraints` call, the coordinator:
1. Creates all constraints (lines 961-984)
2. Activates the "always active" set (lines 987-994)
3. Falls through to the keyboard toggle block (line 1008)
4. Since `lastIsKeyboardVisible = nil`, the toggle fires
5. For keyboard hidden: activates `hostingBottomToVersionLabel` and
   `versionLabelBottomToKeyboard`
6. Calls `layoutIfNeeded()` and measures

Between steps 2 and 5, there's no constraint connecting the hosting view's bottom
to anything. The layout is temporarily underconstrained. Step 5 fixes it, and
step 6 forces layout. But if the keyboard guide position is wrong at step 6,
the measurement is wrong.

---

## 7. Sloppy pattern: `belowBarGap` doesn't match the actual bar position

`belowBarGap` appears in two places with **different semantics**:

1. **In the `listBottomInset` formula** (line 221): represents the assumed
   distance from screen/keyboard bottom to the input bar's bottom edge.
2. **Passed to `KeyboardPinnedContainer` as `desiredBottomGap`** (line 268): used
   as the actual Auto Layout constant for the `hostingBottomToKeyboard` constraint.

When keyboard is **hidden**, `belowBarGap = 24`. But the input bar's actual bottom
position is determined by the version label constraint chain:

```
hosting.bottom = screen.bottom − 4 (versionToKeyboard)
                 − versionLabel.height
                 − 6 (hostingToVersion)
               = screen.bottom − (10 + versionLabel.height)
```

A `caption2` label at default Dynamic Type is ~13pt. So the actual distance is
~23pt, not 24pt. This means `belowBarGap` in the formula doesn't exactly match
reality. The 1pt error is minor, but it's a fragile coupling: if the version
label font or gap constants change, `belowBarGap` silently becomes wrong.

When keyboard is **visible**, `belowBarGap = 12` and is used both in the formula
AND as the actual constraint constant. These agree. No issue here.

---

## 8. Sloppy pattern: `withAnimation(nil)` for keyboard height updates

Line 167:
```swift
withAnimation(nil) { keyboardHeight = height }
```

`withAnimation(nil)` removes the explicit animation transaction but does **not**
suppress implicit animations from `.animation()` modifiers on ancestor views.

Lines 204-205 apply spring animations to toast-related values:
```swift
.animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.toast)
.animation(.spring(response: 0.3, dampingFraction: 0.8), value: channelToastManager.isVisible)
```

If a toast appears on the same frame as a keyboard height change, the spring
animation could theoretically be applied to the keyboard-driven layout change,
causing the inset to animate with a spring instead of snapping.

---

## 9. Sloppy pattern: dead keyboard handler code

Lines 726-765 define `handleKeyboardFrameChange` and `handleKeyboardWillHide`.
These are **never called** — they're remnants of a previous keyboard tracking
strategy. They use `withAnimation(animation)` to animate `keyboardHeight` changes,
which is different from the active `withAnimation(nil)` path. If accidentally
re-enabled, they would produce animated inset changes that lag behind the actual
keyboard.

---

## 10. Sloppy pattern: collection view `viewDidLayoutSubviews` triggers full re-update

Lines 114-154: `viewDidLayoutSubviews` detects bounds changes and calls the full
`update()` method. This means every layout pass that changes `collectionView.frame`
(e.g., from the window bounds extension at lines 120-136) triggers:

1. `forceReconfigureAll = true`
2. `updateLayout()` → clears all size caches, sets `baseBottomInset`, calls
   `applyBottomContentInset()`
3. Full snapshot diff

If `viewDidLayoutSubviews` fires before SwiftUI has pushed the latest
`bottomInset` value (which it does — UIKit layout can run independently of
SwiftUI state propagation), the collection view applies a stale `bottomInset`.
The stale value persists until the next `updateUIViewController` call propagates
the correct value.

---

## 11. Sloppy pattern: `window` nil fallback in keyboard height computation

Line 843-844:
```swift
let screenHeight = window?.windowScene?.screen.bounds.height
    ?? UIScreen.main.bounds.height
```

If the view hasn't been added to a window yet when the first notification fires,
`window` is nil. The fallback to `UIScreen.main.bounds.height` is deprecated in
iOS 16+ and can return incorrect values in multi-display scenarios. More
critically, if the notification fires before the view is in a window, the computed
`height` may not correspond to the correct coordinate space.

---

## 12. Sloppy pattern: force unwrap in coordinator

Line 1010:
```swift
let hasVersionText = versionLabel.text != nil && !versionLabel.text!.isEmpty
```

Safe only because of the preceding nil check, but fragile under refactoring.

---

## 13. Summary: all code paths touching the above-bar gap

| # | Path | File:Line | What it does |
|---|------|-----------|-------------|
| 1 | Formula computation | ChatView.swift:225-226 | Computes `listBottomInset` from four `@State`/environment inputs |
| 2 | Passed to `messageList` | ChatView.swift:235,339 | `bottomInset: listBottomInset` parameter |
| 3 | Passed to `pagedChannelView` | ChatView.swift:231 | Same parameter |
| 4 | Collection view `update()` | MessageFlowCollectionView.swift:314-348 | Stores `bottomInset`, checks for change, calls `updateLayout()` |
| 5 | `updateLayout()` | MessageFlowCollectionView.swift:536-557 | Sets `baseBottomInset`, calls `applyBottomContentInset()`, sets `sectionInset.bottom = containerPadding` |
| 6 | `applyBottomContentInset()` | MessageFlowCollectionView.swift:285-291 | `collectionView.contentInset.bottom = baseBottomInset` (when `usesExternalKeyboardInsets`) |
| 7 | `viewDidLayoutSubviews` | MessageFlowCollectionView.swift:114-154 | On bounds change: `updateLayout()` + full `update()` with **stale** stored `bottomInset` |
| 8 | Content offset adjustment | MessageFlowCollectionView.swift:428-429 | `adjustContentOffsetForBottomInsetChange(delta:)` |
| 9 | `KeyboardPinnedContainer` constraints | ChatView.swift:965-984 | Positions input bar bottom relative to `keyboardLayoutGuide.topAnchor` |
| 10 | Async height measurement | ChatView.swift:1035-1037 | `DispatchQueue.main.async { measuredHeight.wrappedValue = currentHeight }` |
| 11 | `KeyboardLayoutGuideObserverView` | ChatView.swift:838-850 | Notification → `onHeightChange?(height)` → `keyboardHeight = height` |

---

## 14. Ranked race conditions by likelihood

### 1. `keyboardHeight`/`safeAreaInsets.bottom` desync (High)

The keyboard notification and the GeometryProxy update on different schedules.
When they disagree, `isKeyboardVisible` flips to `true` spuriously, adding the
full `keyboardHeight` (34pt) to the inset. This produces a gap that is 22pt too
large on iPhone with home indicator.

**Trigger:** App launch, background→foreground transition, scene activation.
**Self-correction:** Next geometry pass aligns safe area, or next keyboard
notification resets height.

### 2. `viewDidLayoutSubviews` re-applies stale inset (Medium)

When the collection view's frame changes (e.g., extending to window bounds on
first load), `viewDidLayoutSubviews` calls `updateLayout()` with the stored
`bottomInset`, which may be from a previous (wrong) `listBottomInset` value. This
re-applies the stale inset even if SwiftUI has already computed a corrected one.

**Trigger:** First load when the collection view extends to window bounds.
**Self-correction:** Next `updateUIViewController` call from SwiftUI pushes the
correct value.

### 3. Async `inputBarHeight` measurement (Low-Medium)

The one-frame delay from `DispatchQueue.main.async` means `inputBarHeight` (and
thus `resolvedInputHeight`) lags the actual hosting view height. For single-line
input, the 44pt floor masks this. For multi-line input or when the hosting view
initially measures wrong (before constraints resolve), the inset is wrong for one
frame.

**Trigger:** First load; text content that makes the input bar taller than 44pt.
**Self-correction:** Async callback updates height on next run-loop tick.

### 4. Focus/keyboard desync in collection view (Low)

The collection view receives `isKeyboardVisible` from the focus callback (line
341) but `bottomInset` from the keyboard height calculation. These are out of
sync during keyboard transitions. The collection view may make scroll adjustments
(`keyboardJustAppeared` at line 341/422) with the wrong inset.

**Trigger:** Tapping into the input field.
**Self-correction:** Keyboard notification fires, `bottomInset` updates.
