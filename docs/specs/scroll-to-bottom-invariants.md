# Scroll-To-Bottom Indicator — Invariants

**Status:** Draft (invariants-only)

This document defines **behavioral invariants** for the Clawline scroll-to-bottom indicator + unread behavior.

It is intentionally *not* an implementation plan.

**Related:**
- GitHub: clickety-clacks/clawline#42
- Full design/plan spec: `specs/scroll-to-bottom-button.md`

---

## Scope

Applies to the chat message list for a single stream.

This spec covers:
- When the indicator is visible/hidden
- Positioning invariants relative to the input bar + keyboard
- Unread counting/clearing invariants when new messages arrive while scrolled up
- Tap behavior invariants (plain vs unread)

---

## Definitions

- **At bottom**: user is considered “at bottom” when the list is within a small threshold of the end (to avoid flicker due to measurement jitter).
- **Scrolled up**: not at bottom (i.e., there is content below the viewport).
- **Newly appended messages**: messages that appear *after* the previously-known last message id, and only when that previous id is still present in the new list (to avoid counting initial loads/backfills/resets as unread).
- **Unread mode**: indicator has `unreadCount > 0` and a valid `firstUnreadMessageId`.

---

## Invariants (MUST / MUST NOT)

### Visibility
- The indicator **MUST be hidden** when the user is at bottom (i.e. within the bottom threshold).
- The indicator **MUST NOT be shown** when the user is within the bottom threshold (even if not mathematically at the exact last pixel).
- The indicator **MUST be visible** when the user is scrolled up.
- The indicator **MUST NOT flicker** due to tiny layout/float jitter (use an “at bottom” threshold).

### Positioning
- The indicator **MUST be anchored to the input bar/keyboard-pinned container**, so it tracks keyboard show/hide and input bar movement.
- The indicator **MUST remain a consistent offset above the input bar** (target ~12pt) across keyboard transitions.
- The indicator **MUST NOT float mid-screen** after keyboard dismiss or inset changes.

### New messages
- When the user is **at bottom** (within the bottom threshold), receiving newly appended messages **MUST auto-scroll to the very bottom** (preserve the old behavior).
- When the user is **scrolled up**, receiving newly appended messages **MUST NOT auto-scroll** the list.
- When scrolled up, receiving newly appended messages **MUST**:
  - increment `unreadCount` by the number of newly appended messages
  - set `firstUnreadMessageId` once (first time unread becomes non-zero) and keep it stable until cleared
  - trigger a brief attention animation (bounce) at most once per update batch
- Initial load / backfill / stream reset **MUST NOT** generate unread count.

**Note:** This “at-bottom auto-scroll to *very bottom*” behavior historically had race-condition edge cases; any new implementation must preserve correctness under rapid updates (e.g. snapshot apply + typing indicator morph + keyboard/inset transitions).

### Clearing unread state
Unread state **MUST** clear when any of the following occurs:
- the user returns to bottom (indicator hides), or
- the user taps the indicator in unread mode (after performing the unread tap action), or
- while scrolled up with unread state, the user scrolls down until the **top edge** of the `firstUnreadMessageId` bubble crosses the **vertical center** of the viewport.

When clearing via “top-cross-center”:
- The anchored bubble **MUST flash/highlight** as its top edge crosses center (so the user understands what it was), then
- Unread badge **MUST disappear**, and the indicator becomes plain scroll-to-bottom mode.

### Tap behavior
- If `unreadCount == 0`: tap **MUST** scroll to bottom.
- If `unreadCount > 0`: tap **MUST**:
  1) scroll to `firstUnreadMessageId` **centered vertically** (best-effort; clamp near edges)
  2) flash/highlight the target bubble briefly (animation) to show “this is the first unread”
  3) clear unread state (`unreadCount=0`, `firstUnreadMessageId=nil`)
  4) keep the indicator visible if still not at bottom

**Note:** The anchored bubble should also flash/highlight when the user manually scrolls and it crosses the viewport center (see “Clearing unread state”).
- If `firstUnreadMessageId` is missing/stale: unread-mode tap **MUST** fall back to scrolling to bottom and clearing unread state.

### Typing indicator / ephemeral cells
- Typing indicator insertions **MUST NOT** count as unread.
- Morph/transitions **MUST NOT** force an auto-scroll unless the user was already at bottom.

### Multi-stream
- Unread + visibility state **MUST be tracked per stream** (switching streams shows the correct state for the visible stream).

---

## Non-Goals (explicitly not guaranteed)

- Persisting unread state across app restarts.
- Global/combined unread counts across streams.
