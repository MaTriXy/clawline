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
- When the user is **at bottom** (within the bottom threshold), receiving newly appended messages **MUST auto-scroll to the very bottom** — unless the user is actively interacting (finger on screen / dragging). If `wasUserInteracting`, auto-scroll **MAY be deferred** until the interaction ends.
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

## State Machine

The SBB logic **SHOULD** be implemented as an explicit state machine to enforce invariants by construction rather than layered suppression hacks.

### States

| State | Indicator | Unread badge | Auto-scroll | Pinned |
|---|---|---|---|---|
| **AT_BOTTOM** | hidden | — | yes (on new content) | yes |
| **AT_BOTTOM_DRAGGING** | hidden | — | deferred until drag ends | yes |
| **SCROLLED_UP** | visible, no badge | — | no | no |
| **SCROLLED_UP_UNREAD** | visible, badge(N) | shows count | no | no |

### Pinned-to-bottom intent

**This is the core concept that prevents indicator flicker.**

When in any `AT_BOTTOM*` state, the system has **pinned intent** — it considers itself logically at the bottom regardless of transient geometry changes. Content growth, inset changes, layout passes, and typing indicator insertion can all temporarily make `contentOffset` appear "not at bottom." This MUST NOT cause a transition to `SCROLLED_UP`.

**Only an explicit user upward scroll gesture (drag) beyond the threshold can leave `AT_BOTTOM*` states.** Nothing else.

This eliminates the classic race condition:
1. New content arrives → contentSize grows
2. Geometry briefly says "not at bottom" (offset hasn't caught up)
3. ~~Indicator flashes~~ → **No.** Pinned intent means we stay in AT_BOTTOM.
4. Auto-scroll completes → back to actual bottom

### Events

State transitions are triggered by these events only:

| Event | Description |
|---|---|
| **UserScrolled** | Scroll view moved due to user drag or deceleration (e.g. `scrollViewDidScroll`). Used for threshold crossings and unread-anchor center-crossing. |
| **UserDragBegan** | ScrollView tracking began (finger on screen, dragging). |
| **UserDragEnded** | ScrollView tracking/dragging ended (finger lifted). |
| **ContentAppended** | New messages appended (per "newly appended messages" definition — previous last id still present, not initial load/backfill/reset). |
| **ContentMutated** | Content changed without new messages (typing indicator insert/remove, streaming edits, image resize). |
| **InsetsChanged** | Keyboard show/hide, safe-area changes, bounds changes. |
| **IndicatorTapped** | User tapped the scroll-to-bottom indicator. |
| **ScrolledToPosition** | Programmatic scroll completed (auto-scroll or tap-to-unread). |

### Transitions

```
AT_BOTTOM
  → UserDragBegan                          → AT_BOTTOM_DRAGGING
  → UserScrolled (past threshold upward)   → SCROLLED_UP
  → ContentAppended                        → [stay, auto-scroll to bottom]
  → ContentMutated                         → [stay, pinned — no state change]
  → InsetsChanged                          → [stay, pinned — adjust offset to maintain bottom]

AT_BOTTOM_DRAGGING
  → UserDragEnded                          → AT_BOTTOM (+ flush any deferred scroll)
  → UserScrolled (past threshold upward)   → SCROLLED_UP
  → ContentAppended                        → [stay, defer scroll until drag ends]
  → ContentMutated                         → [stay, pinned — no state change]
  → InsetsChanged                          → [stay, pinned]

SCROLLED_UP
  → ContentAppended                        → SCROLLED_UP_UNREAD (set firstUnreadId, count)
  → UserScrolled (to within threshold)     → AT_BOTTOM
  → IndicatorTapped                        → AT_BOTTOM (scroll to bottom)
  → ContentMutated                         → [stay, no state change]
  → InsetsChanged                          → [stay]

SCROLLED_UP_UNREAD
  → ContentAppended                        → [stay, increment count]
  → UserScrolled (to within threshold)     → AT_BOTTOM (clear unread)
  → IndicatorTapped                        → [scroll to firstUnreadId, flash 3x/1s + fade 3s, clear unread]
      → ScrolledToPosition (at bottom)     → AT_BOTTOM
      → ScrolledToPosition (not at bottom) → SCROLLED_UP
  → firstUnread top crosses viewport center → SCROLLED_UP (flash, clear unread)
  → ContentMutated                         → [stay, do NOT increment count]
  → InsetsChanged                          → [stay]
  → firstUnreadId missing from data        → SCROLLED_UP (clear unread — anchor invalidated)
```

### Key constraints

- **Indicator visibility is derived from state, not computed independently.** If state is `AT_BOTTOM` or `AT_BOTTOM_DRAGGING`, indicator is hidden. Period. No "check isNearBottom" race conditions.
- **Pinned intent: content growth never leaves AT_BOTTOM.** Only `UserScrolled` past threshold can transition to `SCROLLED_UP`. ContentAppended, ContentMutated, InsetsChanged all preserve AT_BOTTOM state.
- **State transitions are the ONLY way to change visibility.** Content insertion, inset changes, and layout passes do NOT directly show/hide the indicator — they may trigger a state transition which then updates visibility.
- **"At bottom" determination happens ONCE per event**, not continuously. This eliminates flicker from transient layout states during content update transactions.
- **No suppression deadlines.** No timers. No `suppressAtBottomFalseUntilScrollDeadline`. Pinned intent replaces all suppression hacks.
- **Interaction = scroll view dragging**, not arbitrary touches. Taps, long-press, link taps do NOT enter AT_BOTTOM_DRAGGING.
- **Content update transaction**: snapshot apply → decide/perform scroll → evaluate state once. No intermediate state evaluations during the transaction.
- **Unread anchor validity**: if `firstUnreadMessageId` is missing from the dataset (deleted, filtered, reset), immediately clear unread and transition to SCROLLED_UP.

---

## Non-Goals (explicitly not guaranteed)

- Persisting unread state across app restarts.
- Global/combined unread counts across streams.
