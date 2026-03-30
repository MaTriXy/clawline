# visionOS Platform Invariants

**Status: Authoritative**
**Last updated: 2026-03-30**
**Owner: Flynn**

This document defines the **only valid behavioral differences** between Clawline on visionOS and Clawline on iOS/iPadOS. Any code change that adds new platform-specific behavior, removes an item from this list, or deviates from the rules below **must be raised with Flynn before merging**.

---

## Product rules (immutable)

### 1. Composer does not change on visionOS

The message input area (text field, send button, add button, composer chrome) must **never switch appearance when the theme changes** on Vision Pro. This is a fixed product rule.

On iOS/iPadOS the composer follows the system appearance normally.

### 2. Theme button is the authoritative source of theme on visionOS

All visionOS theme decisions — including what the chat UI, message bubbles, and other views display — derive from the user's theme-button selection (located in the composer, left of the + button). The system appearance is **not** authoritative on visionOS. Only the theme button is.

### 3. Message bubbles and chat UI follow the theme button on visionOS

Outside the composer, all themeable UI (bubbles, headers, settings, etc.) should respond to the theme-button selection, not the system appearance.

### 4. Code blocks and markdown rendering match iOS/iPadOS exactly

There are no visionOS-specific code block or markdown rendering differences. Syntax highlighting, formatting, and rendering behavior must be identical across platforms.

---

## Legitimate platform forks (valid, keep)

These are the only places where visionOS code paths are allowed to differ from iOS/iPadOS:

| Area | What differs | Why valid |
|------|-------------|-----------|
| **Theme button propagation** | One root bridge converts theme-button state into the effective appearance signal. UIKit seams receive explicit dark/light traits derived from this single source. | visionOS does not propagate `colorScheme` from SwiftUI root the same way iOS does. A bridge is required. |
| **Composer appearance** | The composer is locked to a stable appearance and does not respond to theme changes. | Product rule (see above). |
| **Keyboard/input geometry** | Spatial insets, container-bottom pinning, window-bounds geometry, no `keyboardLayoutGuide`. | Spatial windows do not behave like iOS full-screen surfaces. |
| **Single-link preview height cap** | 75% of current window height. | Spatial window sizing differs from iOS screen geometry. Product rule confirmed by Flynn. |
| **Interactive keyboard dismiss** | `keyboardDismissMode = .interactive` is disabled in editor and collection view. | Gesture semantics differ in spatial windows. |
| **Capability gates** | Camera affordances hidden, camera presentation rejected, haptics skipped. | Hardware capability differences. These APIs are unavailable on visionOS. |
| **Material fallbacks** | Solid fills and non-glass materials used where Liquid Glass APIs are unavailable. | API availability difference. |
| **Scroll chrome and edge fade** | Spatial fade treatment on cells near edges, scroll-to-bottom and page dots in SwiftUI bottom overlays rather than UIKit keyboard host. | Spatial window layout and keyboard-host differences. |

---

## Things that are NOT valid visionOS forks

These must not appear in visionOS-specific code paths:

- Syntax highlighting disabled or degraded on visionOS
- Input-lag performance protections existing only on visionOS (these should be cross-platform — if the fix is right for Vision Pro it is right for iPad and iPhone)
- Individual leaf views directly reading `settings.appearanceMode` instead of consuming the propagated theme signal
- Any code path that treats visionOS as having a separate rendering pipeline for message content

---

## Enforcement

When reviewing code changes to the Clawline shared target (`ios/Clawline/Clawline/`):

1. Any new `#if os(visionOS)` block must be justified against this document.
2. If the new divergence is not covered by the legitimate forks table above, **stop and raise it with Flynn**.
3. If a PR removes behavior listed in the legitimate forks table, **stop and raise it with Flynn**.
4. Changes to `MessageInputBar` that affect appearance switching behavior must be reviewed against Product rule #1 above.

This document is the ground truth. Code is evidence of what exists, not authority about what should exist.
