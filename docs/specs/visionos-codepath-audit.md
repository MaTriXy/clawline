# T200: visionOS Codepath Audit

**Date:** 2026-03-29
**Hypothesis:** visionOS has its own code flows in places where it should share them with iPad and iOS.
**Scope:** All `#if os(visionOS)`, `#if !os(visionOS)`, and runtime visionOS checks inside `Clawline/Clawline/` (the shared target). The `Clawline Spatial/` target itself is out of scope — it's the expected host for visionOS-only app entry.

---

## Summary of Findings

| Category | Count | Verdict |
|----------|-------|---------|
| Appearance/color-scheme overrides | ~15 | **Likely consolidatable** — a single "effective color scheme" helper would eliminate the per-view `#if os(visionOS)` pattern |
| Material / glass effect fallbacks | ~10 | **Necessary** — `.glassEffect()` is iOS 26+ / Liquid Glass; visionOS needs `.regularMaterial` fallback |
| Keyboard / layout geometry | ~6 | **Necessary** — spatial windows have different keyboard geometry semantics |
| UIKit feature gating (camera, haptics, SFSafari, keyboard dismiss) | ~6 | **Necessary** — hardware/API not available on visionOS |
| Scroll-cell opacity fade (spatial depth cue) | ~6 | **Questionable** — could be gated by a layout trait rather than platform |
| Snapshot apply logging / timing | 2 | **Unnecessary** — should share the iOS path |
| Bubble sizing (isVisionOS flag) | 2 | **Necessary** — spatial window height capping is genuinely different |
| Page dots / scroll-to-bottom pinning strategy | 4 | **Necessary** — visionOS lacks keyboardLayoutGuide pinning |
| Input bar z-offset | 1 | **Necessary** — spatial affordance (`offset(z:)`) is visionOS-only API |

**Bottom line:** Roughly **15 out of ~52 `#if os(visionOS)` sites** are appearance/theme overrides that repeat the same pattern (`settings.appearanceMode == .dark` vs `colorScheme`). These should be consolidated into a shared helper. The remaining ~37 sites are either necessary platform divergence or could be lightly refactored but are defensible.

---

## Detailed Inventory

### 1. Appearance / Color Scheme Overrides (CONSOLIDATION CANDIDATE)

On visionOS the system `colorScheme` environment value doesn't update when the user toggles appearance in Clawline's settings, so every view manually checks `settings.appearanceMode`. On iOS/iPad, the system `colorScheme` is the source of truth. This creates a scattered `#if os(visionOS) / settings.appearanceMode / #else / colorScheme / #endif` pattern repeated in many files.

| File | Line(s) | What it does |
|------|---------|--------------|
| `Settings/SettingsView.swift` | 17 | `effectiveColorScheme` reads `settings.appearanceMode` on visionOS, `colorScheme` on iOS |
| `DesignSystem/.../ScrollToBottomButton.swift` | 22 | `resolvedScheme` — same pattern |
| `DesignSystem/.../CodeBlockView.swift` | 28 | `isDark` — same pattern |
| `DesignSystem/.../MessageInputBar.swift` | 128 | `isLightModeForInputBar` — forces dark on visionOS (#61) |
| `Views/Chat/ChannelToast.swift` | 21 | `isDarkMode` — same pattern |
| `Views/Chat/ChatView.swift` | 2836 | `effectiveColorScheme` in `AttachmentPickerOverlay` — same pattern |
| `Views/Chat/ChatView.swift` | 2908 | `effectiveColorScheme` in `AttachmentActionButton` — same pattern |
| `Views/Chat/ExpandedMessageSheet.swift` | 28 | `effectiveColorScheme` — same pattern |
| `Views/Chat/MessageFlowCollectionView.swift` | 46, 76 | `isDark` in make/update — same pattern |
| `Views/Chat/MessageFlowCollectionView.swift` | 1992-1997 | `overrideUserInterfaceStyle` set only on visionOS |
| `Views/RootView.swift` | 59 | `.preferredColorScheme(settings.preferredColorScheme)` only on visionOS |

**Recommendation:** Create a shared `effectiveColorScheme` computed property or environment key that resolves correctly on both platforms. Wire it once at `RootView` level, eliminating all per-view `#if os(visionOS)` appearance checks. The `overrideUserInterfaceStyle` in MessageFlowCollectionView would still need to exist but could read from the same single source.

---

### 2. Material / Glass Effect Fallbacks (NECESSARY)

visionOS does not support iOS 26's `.glassEffect()` modifier. These sites use `.background(.regularMaterial)` + a border stroke on visionOS vs `.glassEffect(.regular)` on iOS.

| File | Line(s) | Component |
|------|---------|-----------|
| `DesignSystem/.../ScrollToBottomButton.swift` | 52-56 | Scroll-to-bottom button circle |
| `DesignSystem/.../MessageInputBar.swift` | 207, 237, 382, 512 | Add button, attachment button, text field, send button |
| `Views/Chat/StreamPageDotsView.swift` | 82 | Page dots capsule (iOS-only `.glassEffect`) |
| `Views/Chat/ChatView.swift` | 1936 | Empty-state pill background |
| `Views/Chat/ChatView.swift` | 2939 | Attachment action button background |
| `Views/Chat/ChannelToast.swift` | 69 | Toast background |
| `Views/Pairing/PairingView.swift` | 167, 203, 233, 277, 319 | Pairing field backgrounds and submit buttons |

**Verdict:** Necessary. Liquid Glass is not available on visionOS. When/if Apple ships `.glassEffect()` for visionOS, these can be unified.

---

### 3. Keyboard / Layout Geometry (NECESSARY)

Spatial windows have different keyboard-related behavior — the keyboard can "over-report" its height, there's no physical home indicator, and `keyboardLayoutGuide` doesn't behave the same way.

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/ChatView.swift` | 693-696 | `usesExternalKeyboardInsets = true` — bypasses keyboard geometry on visionOS |
| `Views/Chat/ChatView.swift` | 2172-2175 | Keyboard height calculation uses window bounds instead of screen height on visionOS |
| `Views/Chat/ChatView.swift` | 2330-2336 | Skips `keyboardLayoutGuide.usesBottomSafeArea = false` on visionOS |
| `Views/Chat/ChatView.swift` | 2470, 2517 | `setDesiredBottomGap`/`ensureConstraints` — pins to container bottom instead of `keyboardLayoutGuide` on visionOS |
| `Views/Chat/MessageFlowCollectionView.swift` | 936 | `collectionView.frame = view.bounds` instead of window-frame extension — prevents layout feedback loop on visionOS |

**Verdict:** Necessary. visionOS spatial windows have fundamentally different keyboard geometry semantics.

---

### 4. UIKit Feature Gating (NECESSARY)

Features that don't exist or don't apply on Vision Pro.

| File | Line(s) | What it does |
|------|---------|--------------|
| `DesignSystem/.../CameraPicker.swift` | 8 | Entire file wrapped in `#if !os(visionOS)` — camera picker unavailable |
| `Views/Chat/ChatView.swift` | 1361-1365 | `.camera` sheet case shows `Color.clear` + dismisses on visionOS |
| `Views/Chat/ChatView.swift` | 1683-1686 | `presentCamera()` shows `.cameraUnavailable` toast on visionOS |
| `Views/Chat/ChatView.swift` | 2866 | Hides "Camera" button from attachment picker on visionOS |
| `ViewModels/ChatViewModel.swift` | 646-649 | `assistantIncomingHaptic` — no haptic engine on visionOS |
| `Views/Chat/ChatView.swift` | 798-801 | Stream-switch haptic — no haptic engine on visionOS |
| `DesignSystem/.../RichTextEditor.swift` | 49 | Skips `.keyboardDismissMode = .interactive` on visionOS |
| `Views/Chat/MessageFlowCollectionView.swift` | 3159 | Skips `.keyboardDismissMode = .interactive` on visionOS |
| `Views/Chat/LinkCardUIKitView.swift` | 272 | Opens URL with `UIApplication.shared.open` on visionOS (no SFSafariViewController) |
| `Views/Chat/LinkPreviewView.swift` | 864 | Opens URL with `UIApplication.shared.open` on visionOS (no SFSafariViewController) |

**Verdict:** Necessary. These are correct platform capability gates.

---

### 5. Scroll-Cell Opacity Fade (QUESTIONABLE)

On visionOS, cells near the top and bottom edges of the collection view are faded in/out for a spatial depth cue. This is a visionOS-only ~30-line function (`updateVisibleCellOpacity`) called from multiple scroll delegate methods.

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/MessageFlowCollectionView.swift` | 986-988 | Calls `updateVisibleCellOpacity()` after layout |
| `Views/Chat/MessageFlowCollectionView.swift` | 991-1018 | The `updateVisibleCellOpacity()` function itself |
| `Views/Chat/MessageFlowCollectionView.swift` | 1023-1025 | Calls during `scrollViewDidScroll` |
| `Views/Chat/MessageFlowCollectionView.swift` | 1036-1039 | Calls in `scrollViewDidEndDragging` |
| `Views/Chat/MessageFlowCollectionView.swift` | 1058-1060 | Calls in `scrollViewDidEndDecelerating` |
| `Views/Chat/MessageFlowCollectionView.swift` | 1110-1112 | Calls in `willDisplay cell` instead of iOS appearance animation |

**Recommendation:** This is a visual nicety for spatial mode. It's defensible as-is, but could be made more portable by keying off a layout trait or a configuration flag rather than a compile-time OS check. If iPad ever wants a similar fade (e.g., for Stage Manager windows), the current gating would need refactoring.

---

### 6. Message Bubble Fade Location (MINOR)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/MessageBubbleUIKitView.swift` | 1095-1098 | `setFadeStartLocation(0.95)` on visionOS vs `nil` on iOS |
| `Views/Chat/MessageBubbleUIKitView.swift` | 1251-1254 | Skips scroll indicator inset adjustment on visionOS |

**Verdict:** The fade tuning (0.95 vs nil) is a spatial visual tweak — defensible. The scroll indicator inset skip might be masking a real issue on visionOS where indicator insets don't behave correctly.

---

### 7. Snapshot Apply / Timing Logging (UNNECESSARY DIVERGENCE)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/MessageFlowCollectionView.swift` | 2204-2223 | visionOS logs `StreamSwitchTiming.log("dataSource_apply_start")` before snapshot apply; iOS uses a different animation path |
| `Views/Chat/MessageFlowCollectionView.swift` | 2226-2245 | Same pattern for non-morph apply |

**Recommendation:** The logging should happen on all platforms. The actual divergence here is in the animation path (visionOS uses a simpler apply without the iOS animation wrapper), which may be worth investigating — it's unclear if the animation difference is intentional or a leftover from early porting.

---

### 8. Bubble Sizing (isVisionOS flag) (NECESSARY)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/BubbleSizingV2.swift` | 22, 94 | `isVisionOS` in Environment struct; caps single-link bubbles at 75% window height on visionOS |
| `Views/Chat/MessageFlowCollectionView.swift` | 3487-3490 | `effectiveContainerHeight()` caps at `bubbleReferenceSize.height` on visionOS |
| `Views/Chat/MessageFlowCollectionView.swift` | 3514-3530 | `shouldDisableOuterScrollForMixedMediaBubble` — different scroll-disable logic on visionOS |
| `Views/Chat/MessageFlowCollectionView.swift` | 3868-3871 | Sets `isVisionOS` flag for BubbleSizingV2.Environment |
| `Views/Chat/MessageFlowCollectionView.swift` | 4931-4934 | `snapToPixel` — reads displayScale from traitCollection on visionOS (no window scene / screen) |

**Verdict:** Necessary. Spatial window sizing constraints are genuinely different from iOS screen-based layout.

---

### 9. Chat View Layout — Top/Bottom Insets (NECESSARY but heavy-handed)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/ChatView.swift` | 660-661 | Adds 25% of window height as top inset on visionOS (pushes messages down in spatial window) |
| `Views/Chat/ChatView.swift` | 667-668 | Adds 25% of window height as additional bottom inset on visionOS |
| `Views/Chat/ChatView.swift` | 506-507 | `Color.clear` background on visionOS (transparent window) |
| `Views/RootView.swift` | 93-96 | `Color.clear` background on visionOS |
| `Views/Chat/ChatView.swift` | 1400-1401 | `Color.clear` background for settings sheet on visionOS |

**Verdict:** Mostly necessary — transparent backgrounds and spatial insets are core to the visionOS window experience. The 25% inset values are magic numbers that could be configuration-driven.

---

### 10. Page Dots / Scroll-To-Bottom Button Pinning (NECESSARY)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/ChatView.swift` | 831-834 | visionOS uses floating page dots in SwiftUI overlay; iOS pins to keyboardLayoutGuide |
| `Views/Chat/ChatView.swift` | 853-856 | visionOS places scroll-to-bottom button in SwiftUI overlay; iOS pins via UIKit |
| `Views/Chat/ChatView.swift` | 1181-1184 | visionOS nil-s out the pinned scroll button (handled elsewhere) |
| `Views/Chat/ChatView.swift` | 1328-1330 | Returns list directly on visionOS (no keyboard-pinned container wrapper) |
| `Views/Chat/ChatView.swift` | 2369-2375 | `updateScrollButton` is a no-op on visionOS |
| `Views/Chat/ChatView.swift` | 2430-2433 | `updatePageDots` is a no-op on visionOS |

**Verdict:** Necessary. visionOS doesn't have `keyboardLayoutGuide` pinning in the same way. The SwiftUI overlay approach is the right strategy for spatial windows.

---

### 11. Input Bar Depth Offset (NECESSARY)

| File | Line(s) | What it does |
|------|---------|--------------|
| `Views/Chat/ChatView.swift` | 1253, 1964-1978 | `VisionOSInputBarDepthOffset` — applies `content.offset(z: 24)` on visionOS, passthrough on iOS |

**Verdict:** Necessary. Z-offset is a visionOS-only spatial affordance. The modifier pattern is clean.

---

### 12. Non-divergent visionOS Availability Annotations (NOT DIVERGENCE)

These are `@available(iOS 26.0, visionOS 3.0, *)` annotations or `#available` checks that include visionOS as a supported platform alongside iOS. They do NOT create divergent behavior.

| File | Line(s) |
|------|---------|
| `Services/SalientHighlightService.swift` | 160, 350, 398, 472 |
| `Views/Chat/InteractiveHTMLBubbleUIKitView.swift` | 343 |
| `Views/Chat/LinkPreviewView.swift` | 50, 502, 561 |
| `Views/Chat/MessageBubbleUIKitView.swift` | 36 |
| `Views/Chat/ChatView.swift` | 2315, 2444 |

**Verdict:** No action needed. These are standard multi-platform availability annotations.

---

## Recommendations

### High Priority: Consolidate Appearance Theme Checks

Create a shared `effectiveColorScheme` utility:

```swift
// In a shared extension, e.g. DesignSystem/ThemeResolution.swift
extension View {
    var resolvedColorScheme: ColorScheme {
        #if os(visionOS)
        // On visionOS, the system color scheme doesn't follow our in-app toggle.
        // Read from settings directly.
        return settings.appearanceMode == .dark ? .dark : .light
        #else
        return colorScheme
        #endif
    }
}
```

Or better: wire `.preferredColorScheme()` at the root on both platforms (not just visionOS as currently done in `RootView.swift:59`) so the system `colorScheme` environment propagates correctly on visionOS too, eliminating the need for `settings.appearanceMode` checks entirely.

This single change would eliminate **~15 `#if os(visionOS)` blocks** and reduce the visionOS divergence surface by ~30%.

### Medium Priority: Investigate Snapshot Apply Divergence

The different animation paths in `MessageFlowCollectionView.swift:2204-2245` for morph/non-morph snapshot applies may be an unintentional artifact. Verify whether visionOS can use the same animation wrapper as iOS.

### Low Priority: Configuration-Driven Instead of Compile-Time

Several sites (cell opacity fade, 25% spatial insets, bubble height caps) use compile-time `#if os(visionOS)` for values that could be configuration-driven or trait-based. This would make the codebase more testable and allow iPad to adopt spatial-like behaviors in the future.

---

## Clawline Spatial Target

The `Clawline Spatial/` target contains exactly 2 files:
- `Clawline_SpatialApp.swift` — App entry point with `.windowStyle(.plain)`, identical DI setup to `ClawlineApp.swift`
- `ContentView.swift` — Minimal content wrapper

This is the expected structure for a separate visionOS app entry point and is not a concern.
