# Scroll-To-Bottom Button With Unread Indicator

## Goal
Add a floating scroll-to-bottom button in Clawline chat that:
- Appears when the user is not at the bottom of the message list.
- Does not auto-scroll when new messages arrive while the user is scrolled up.
- Shows an unread counter badge and bounces when new messages arrive while scrolled up.
- Supports two tap behaviors:
  - Plain: scroll to bottom.
  - Unread: scroll to the first unread message, vertically centered, then clear unread state.

This implements GitHub issue clickety-clacks/clawline#42.

## Non-Goals
- Cross-stream/global notification UI (for example, showing a combined unread count for an inactive stream while viewing another stream).
- Persisting unread state across app restarts.
- Changing message read semantics elsewhere in the app.

## User-Facing Behavior

### Visibility
- Button is visible when there is content below the viewport (user is scrolled up).
- Button is hidden when the user is at the bottom (no content below viewport).

We treat “at bottom” as “within a small threshold” to avoid flicker due to floating point/layout jitter.

### New Messages While Scrolled Up
- Do not auto-scroll.
- Button bounces briefly.
- Unread badge appears and increments as additional new messages arrive.

### Tap Behavior
- If unread count is 0: scroll to bottom.
- If unread count > 0:
  1. Scroll to the first unread message, using centered vertical positioning.
  2. Clear unread count/badge and forget the first-unread anchor.
  3. Keep the button visible (the user is typically still not at the absolute bottom).

### Clearing Unread State
Unread state is cleared when:
- The user reaches the bottom (button hides), or
- The user taps the button in unread mode (after scrolling to first unread).

## Design
- Placement: bottom-trailing, above the input bar.
- Visual style: match the existing ChatFlowOrganic design system.
  - Use `glassEffect`/material + `ChatFlowTheme` colors (no ad-hoc hex literals).
- Badge: small pill/dot overlaid on the button. Show `99+` when count exceeds 99.
- Animations:
  - Fade in/out on visibility change.
  - Brief bounce when new unread messages arrive.

Accessibility:
- Button label changes based on mode:
  - Plain: “Scroll to bottom”.
  - Unread: “Scroll to first unread message”.
- Badge exposes unread count via accessibility value.

## Architecture / Implementation Plan

### Components
1. **SwiftUI button view**
   - New component in `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/`.
   - API:
     - `isVisible: Bool`
     - `unreadCount: Int`
     - `onTap: () -> Void`
     - `bounceToken: Int` (increment to trigger bounce)

2. **Scroll state + unread state owner (ChatView)**
   - `ChatView` owns UI state per stream (`ChatStream`), but only renders the button for the currently visible stream:
     - `isScrollButtonVisibleByStream`
     - `unreadCountByStream`
     - `firstUnreadMessageIdByStream`
     - `bounceTokenByStream`
   - On stream switch, the visible button reflects that stream’s state.
   - `ChatView` overlays the button at `.bottomTrailing` and positions it above the input bar using the same geometry used by `StreamToast` (but without the toast’s additional +50 offset).

3. **UIKit list event source (MessageFlowCollectionViewController)**
   - Extend `MessageFlowCollectionView` to accept a callback for scroll events.
   - `MessageFlowCollectionViewController` emits:
     - Bottom proximity changes (`isAtBottom` boolean).
     - “New messages arrived while not at bottom” events with the list of new message ids.

### Preventing Auto-Scroll
Currently, the list schedules `scrollToBottom` whenever the newest message id changes.

Change:
- Capture `wasAtBottomBeforeUpdate` and `wasUserInteracting` at the start of `update(...)` (before applying the snapshot).
- When the newest message id changes:
  - If `wasAtBottomBeforeUpdate` and `!wasUserInteracting`, keep existing auto-scroll behavior.
  - Otherwise, do not scroll; emit a “new messages while scrolled up” event.

Typing indicator morph integration:
- Preserve existing morph behavior (no concurrent scroll animations during morph).
- Only schedule any deferred scroll-to-bottom after morph completion if the user was at bottom when the morph began (same `wasAtBottomBeforeUpdate` gate).

### Computing “New Messages” Robustly
Avoid counting initial loads, backfills, or channel switches as unread.

Approach:
- Before update: store `previousLastMessageId`.
- After determining the new `messages` array:
  - If `previousLastMessageId` exists and is found in the new array, treat messages after it as newly appended.
  - Otherwise, treat as no newly appended messages for unread purposes.

Notes:
- This logic naturally excludes typing indicator insertions because the unread calculation is based on the `messages` array (not the diffable snapshot which includes the typing indicator cell).
- Bounce is triggered once per update batch if at least one newly appended message is detected.

### Scrolling To First Unread (Centered)
Add a controller method:
- `scrollToMessageCentered(messageId:animated:)`

Implementation:
- Find indexPath for the message id.
- Compute a target `contentOffset.y` so the cell’s vertical center aligns with the visible rect’s vertical center (clamped to valid scroll range).
  - This avoids `.centeredVertically` edge behavior that can fail to truly center near the top/bottom.

Expose to SwiftUI:
- Add methods on `ChatLayoutCoordinator` to call into the active list controller (it already stores weak list refs by stream).

### Stream Handling
- Events emitted from list controllers include the stream (`ChatStream`).
- `ChatView` updates per-stream state for any stream that emits events, but only renders the button for the currently visible stream.

## Edge Cases
- If the first unread message id is no longer present (stream switch, history reset, etc.), tapping unread falls back to scrolling to bottom and clears unread state.
- If multiple messages arrive in one update, unread count increments by the number of appended messages.
- Typing indicator insertions do not count as unread, and do not trigger bounce/unread updates.

## Test Plan
- Unit tests for helper logic that computes appended message ids given `previousLastMessageId` and the new message id list.
- Manual verification:
  1. Scroll up: button appears.
  2. Receive new message: no auto-scroll; badge increments; button bounces.
  3. Tap in unread mode: list scrolls to first unread (centered); badge clears; button remains.
  4. Tap in plain mode: scrolls to bottom; button hides.
  5. visionOS: verify placement above input bar and no layout “flapping”.
  6. Multi-stream (admin + personal): scroll states and unread counts are independent; switching streams shows the correct button state for the visible stream.
  7. Keyboard show/hide while scrolled up: button remains correctly positioned above the input bar.

## Rollout / Risk
- Risk: scroll position regressions (especially around keyboard/inset transitions).
- Mitigation:
  - Keep keyboard/inset system unchanged.
  - Limit changes to: message insertion auto-scroll gating + new overlay UI.
