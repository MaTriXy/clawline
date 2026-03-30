# visionOS Platform Invariants

**Status: Authoritative**
**Last updated: 2026-03-30**
**Owner: Flynn**

> This document defines the **complete and exhaustive list** of valid behavioral differences between Clawline on visionOS and Clawline on iOS/iPadOS.
>
> **Default rule: share the code. Every `#if os(visionOS)` block requires justification against this document.**
>
> If a change you are making adds a new platform fork, removes a listed fork, or changes behavior in a way not covered below — **stop and raise it with Flynn before committing**. Do not make a judgment call. Do not infer intent from the existing code. Ask.

---

## Product rules (locked — not subject to agent interpretation)

### Rule 1: Composer does not change on visionOS

The message input area (text field, send button, add button, and all composer chrome) must **never change appearance when the user switches theme** on Vision Pro.

This is a fixed product rule. It is not a workaround and it is not up for re-evaluation. The composer is visually stable.

On iOS/iPadOS the composer follows the system appearance normally.

### Rule 2: Theme button is the only source of theme truth on visionOS

The theme toggle button (in the composer, left of the + button) is the **sole authority** for what theme is active on Vision Pro. The system appearance setting is ignored. Everything that is allowed to follow theme on visionOS follows this button — not the OS.

### Rule 3: Code blocks and markdown render identically across platforms

There are no visionOS-specific code block, syntax highlighting, or markdown rendering differences. Whatever renders on iPhone/iPad must render identically on Vision Pro.

---

## Valid platform forks (the complete list)

These are the **only** `#if os(visionOS)` distinctions that are currently permitted in the shared `ios/Clawline/Clawline/` target. Each entry has an explicit reason. "We've always done it this way" is not a reason.

| # | Area | What differs on visionOS | Why it is valid |
|---|------|--------------------------|-----------------|
| 1 | **Theme propagation bridge** | A single root bridge translates the theme-button state into the effective `colorScheme`/UIKit trait used by the app tree. UIKit-hosted seams (MessageFlowCollectionView, SelectableAttributedText, MessageBubbleUIKitView) receive explicit dark/light style values from this one source. | SwiftUI on visionOS does not propagate `colorScheme` from the window root the same way iOS does. A deterministic bridge is required. |
| 2 | **Composer appearance lock** | The composer's visual appearance is pinned and does not respond to theme changes. | Product Rule 1. |
| 3 | **Theme button placement and wiring** | The theme toggle button lives in the composer on Vision Pro. Its state drives the rest of the visionOS theme system. | Product Rule 2. |
| 4 | **Keyboard and window geometry** | Spatial insets (25% top/bottom), container-bottom pinning instead of `keyboardLayoutGuide`, keyboard height sampled from window bounds, collection view kept in `view.bounds` not extended to window. | Spatial windows do not behave like iOS full-screen surfaces. Layout coordinates differ fundamentally. |
| 5 | **Single-link preview height cap** | Single-link preview bubbles cap at 75% of the current window height. | Spatial window height is not equivalent to iOS screen height. Cap confirmed by Flynn. |
| 6 | **Interactive keyboard dismiss** | `.keyboardDismissMode = .interactive` disabled in both the editor and the collection view. | The swipe-dismiss gesture model does not apply in a spatial window. |
| 7 | **Capability gates** | Camera affordances hidden, camera presentation blocked, haptic feedback skipped. | These hardware capabilities are absent on Vision Pro. |
| 8 | **Material fallbacks** | Solid fills and non-glass surfaces where Liquid Glass APIs are unavailable. | API availability difference, not a design preference. |
| 9 | **Scroll chrome placement** | Scroll-to-bottom button and page dots rendered in SwiftUI bottom overlays instead of the UIKit keyboard host layer. | The keyboard host layout model differs in spatial windows. |

---

## Things that are explicitly NOT valid visionOS forks

Do not add `#if os(visionOS)` blocks that produce any of the following. If existing code does this, it is a known defect and should be cleaned up, not copied:

- Syntax highlighting disabled or degraded
- Markdown processing different from iOS/iPad
- Input-lag performance protections existing only on visionOS (if the fix is correct for Vision Pro it belongs on all platforms)
- Individual leaf views reading `settings.appearanceMode` to decide their own theme instead of consuming the propagated signal
- Any per-view appearance fork that bypasses the root theme bridge
- Any spatial sizing rule beyond entry #5 (the 75% single-link cap) without Flynn sign-off

---

## Before adding a new `#if os(visionOS)` block

Ask yourself:
1. Is this divergence listed in the valid forks table above?
2. If yes — is your change consistent with the stated reason?
3. If no — stop. Write down what you want to do and why, and raise it with Flynn.

**Do not assume the answer is yes. Do not infer from similar existing forks. Ask.**

---

## Enforcement summary

- New fork not in the table → raise with Flynn first
- Removal of an entry in the table → raise with Flynn first
- Change to `MessageInputBar` that touches appearance behavior → verify against Rule 1
- Change to theme propagation path → verify against Rules 2 and 3
- Code review finding a new `#if os(visionOS)` not in the table → block merge, raise with Flynn
