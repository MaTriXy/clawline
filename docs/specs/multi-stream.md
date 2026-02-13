# Clawline Multi-Stream Support

Status: Draft
Last updated: 2026-02-11
Source issue: clickety-clacks/clawline#71

## 1. Overview

This spec defines multi-stream chat support for Clawline with:
- Multiple named streams (beyond Main/DM/Global DM)
- Page indicator + stream manager popup UX
- Stream forking and merge-back summarization
- Message-level fork attribution and navigation
- Per-stream filtering/collapse behavior integration

This document is implementation-oriented and normative where it uses MUST/SHOULD.

## 2. Goals

1. Let users create, rename, delete, fork, and merge streams with clear structure.
2. Preserve routing invariants: each stream maps to exactly one session key.
3. Make branch relationships obvious in UI, especially when multiple forks exist.
4. Keep cross-device behavior deterministic with ordered, replayable updates.
5. Keep transport practical: real-time updates on WebSocket, mutating actions via REST.

## 3. Non-Goals

1. Automatic semantic merge of full fork history into parent (merge is summary-only).
2. Arbitrary drag-and-drop page reordering in v1.
3. Global unread rollups across every stream in this spec.
4. Full version-control-style history rewrite/rebase/cherry-pick.

## 4. Core Invariants

1. Session keys remain canonical routing identity. No alternate routing IDs.
2. One stream equals one session key.
3. Stream hierarchy is a tree (single parent per stream, no cycles).
4. Forking captures parent history up to an anchor message ID, then diverges.
5. Merge is compaction-style summary into parent as one message, never message interleaving.
6. Fork provenance must be visible in both parent and child:
   - Parent: fork indicator anchored to the exact source message
   - Child: top-of-stream fork origin bubble + persistent fork identity indicator

## 5. Data Model

### 5.1 Stream Node (session tree)

Each stream is represented as a node in a per-user stream tree.

```ts
type StreamNode = {
  sessionKey: string;             // canonical stream/session identity
  displayName: string;
  parentId: string | null;        // parent sessionKey; null for root streams
  rootKind: "main" | "dm" | "global_dm" | "custom";
  forkOriginMessageId?: string;   // required when parentId != null
  forkReason?: string;            // optional user/provider reason shown in child origin bubble
  forkCreatedBy: "user" | "provider";
  orderKey: string;               // stable lexicographic ordering token
  isArchived: boolean;
  createdAt: number;              // unix ms
  updatedAt: number;              // unix ms
  lastMessageAt?: number;
  lastMessageId?: string;
  treeVersion: number;            // monotonic topology version for sync
};
```

Notes:
- `sessionKey` and `parentId` are opaque to client logic except equality and linking.
- `parentId` null identifies root pages.
- Fork streams MUST set `parentId` and `forkOriginMessageId`.

### 5.2 Message-level fork metadata

Messages in parent streams may carry attached fork references:

```ts
type MessageForkRef = {
  forkSessionKey: string;
  sourceMessageId: string;        // message this fork was created from
  createdAt: number;
};
```

A parent message can map to zero, one, or many fork refs.

### 5.3 Merge provenance metadata

When a fork is merged, parent receives a normal message with merge metadata:

```ts
type MergeMetadata = {
  mergedFromSessionKey: string;
  mergedIntoSessionKey: string;
  mergedByUserId: string;
  mergedAt: number;
};
```

This metadata is for UI provenance and auditing, not alternate routing.

### 5.4 Example tree

```json
{
  "streams": [
    { "sessionKey": "agent:main:clawline:flynn:main", "displayName": "Main", "parentId": null, "orderKey": "1000" },
    { "sessionKey": "agent:main:clawline:flynn:main:fork:a1", "displayName": "Main - fork A", "parentId": "agent:main:clawline:flynn:main", "forkOriginMessageId": "s_101", "orderKey": "1001" },
    { "sessionKey": "agent:main:clawline:flynn:main:fork:b2", "displayName": "Main - fork B", "parentId": "agent:main:clawline:flynn:main", "forkOriginMessageId": "s_120", "orderKey": "1002" },
    { "sessionKey": "agent:main:main", "displayName": "Global DM", "parentId": null, "orderKey": "2000" }
  ]
}
```

## 6. Page Ordering Rules

Ordering must be deterministic across devices.

1. Root streams keep fixed baseline order by product policy:
   - `Main`, `Personal DM` (if visible), `Global DM` (if visible), then user-created roots.
2. New non-fork stream (Add) appends to far right.
3. Forked stream inserts immediately to the right of its parent stream.
4. If multiple forks are created from the same parent, they appear to the right of parent in creation order.
5. Existing pages to the right shift rightward when a fork is inserted.
6. Deleting a page compacts indices leftward; no gaps in visible paging order.
7. Archived streams are excluded from page dots but remain visible in stream manager under "Archived".
8. Ordering derives from `orderKey`; do not rely on local insertion timing.

Recommended `orderKey` policy: fractional indexing or server-assigned monotonic sparse keys to avoid global renumbering.

## 7. UI Components

### 7.1 Page Indicator (dots)

1. Horizontal page dots represent currently visible (non-archived) streams.
2. Current stream dot is highlighted.
3. Tapping the dots area opens Stream Manager popup.
4. Dot ordering follows section 6.

### 7.2 Stream Manager Popup

1. Scrollable stream list with fixed bottom toolbar.
2. Bottom toolbar is pinned and non-scrolling.
3. Toolbar actions: Add, Rename, Delete, Fork, Merge.
4. Selecting a stream in the list pages to that stream.
5. Archived section is collapsed by default.

### 7.3 Fork Indicator on Parent Message (refinement)

This is required behavior:

1. When provider creates a fork, indicator attaches to the exact source message bubble.
2. Indicator is message-anchored (like a reply marker), never a floating edge pill.
3. If multiple forks originate from one message, indicator shows count (for example "Forks 2").
4. Tapping indicator opens fork picker when count > 1, otherwise pages directly to that fork.
5. Indicator persists as long as fork exists (or until archived policy hides archived refs).

### 7.4 Fork Origin Bubble at Top of Child Stream (refinement)

1. Every forked stream starts with a design-system origin bubble pinned at top of history.
2. Bubble explains why stream exists using `forkReason` when present.
3. Bubble includes source context:
   - Parent stream name
   - Truncated snippet of source message
   - Created timestamp
4. Bubble action: "Go to source message" pages to parent and scrolls to source message.

### 7.5 Persistent Fork Identity Indicator (refinement)

1. Forked sessions display a persistent identity indicator in header/chrome.
2. Indicator states this stream is a fork.
3. Tapping opens panel with:
   - Parent stream name
   - Source message timestamp
   - "Go to parent" action (pages to parent)
4. Indicator persists for lifetime of fork (including after merge unless fork deleted).

### 7.6 Content Controls Integration (#13)

1. Filter/collapse state is tracked per stream.
2. "My messages only" collapse in a fork must not affect parent stream view state.
3. Tapping collapsed item restores full context in same stream only.

## 8. Interaction Flows

### 8.1 Add stream

1. User opens stream manager and taps Add.
2. User enters name.
3. Server creates root stream node with `parentId: null`, appends right.
4. Client pages to new stream.

### 8.2 Rename stream

1. User selects stream and taps Rename.
2. Name update persists to node `displayName`.
3. All devices receive update event and refresh labels.

### 8.3 Delete stream

1. Only leaf streams are deletable in v1.
2. Attempting to delete non-leaf stream returns conflict error.
3. Delete removes stream from paging and stream manager active list.
4. Optional archive mode may convert delete to archive by policy.

### 8.4 Fork stream at message

1. User long-presses/selects message and taps Fork (or provider auto-forks with reason).
2. Source message must be finalized (not mid-streaming partial).
3. Server creates child node with:
   - `parentId` = parent sessionKey
   - `forkOriginMessageId` = selected message ID
   - inherited history through selected message inclusive
4. Child inserts immediately right of parent.
5. Parent source message receives fork indicator.
6. Child top shows fork origin bubble.
7. Child header shows persistent fork identity indicator.

### 8.5 Navigate between parent and fork

1. Parent -> fork: tap message-anchored fork indicator.
2. Fork -> parent: tap persistent fork identity indicator, then "Go to parent".
3. Fork origin bubble can also jump to exact source message in parent.

### 8.6 Merge fork into parent

1. User opens Merge action from fork stream.
2. UI presents editable summary draft composer (provider-suggested or empty template).
3. User edits summary.
4. On confirm, server posts one summary message into parent with merge metadata.
5. User chooses post-merge action:
   - Keep fork (active/archive)
   - Delete fork (if leaf)
6. Parent and child are never interleaved message-by-message.

## 9. Transport Design: WebSocket vs REST

This feature uses a hybrid transport.

### 9.1 WebSocket (real-time event plane)

WebSocket remains source for:
1. Live chat message events (existing)
2. Stream topology change events (create/rename/delete/fork/merge side effects)
3. Cross-device synchronization and replay ordering

Additions to server -> client event schema:

```ts
type StreamEvent =
  | { type: "stream_snapshot"; treeVersion: number; streams: StreamNode[] }
  | { type: "stream_created"; treeVersion: number; stream: StreamNode }
  | { type: "stream_updated"; treeVersion: number; stream: StreamNode }
  | { type: "stream_deleted"; treeVersion: number; sessionKey: string }
  | { type: "stream_merged"; treeVersion: number; merge: MergeMetadata };
```

Message events MUST include `sessionKey` so client can route message to correct page.

### 9.2 REST (command and heavy response plane)

REST endpoints (same auth token model, same host/port) handle user commands:

1. `GET /api/streams` -> current stream tree snapshot
2. `POST /api/streams` -> create root stream
3. `PATCH /api/streams/:sessionKey` -> rename/archive
4. `DELETE /api/streams/:sessionKey` -> delete leaf stream
5. `POST /api/streams/:sessionKey/fork` -> create fork from message
6. `POST /api/streams/:sessionKey/merge` -> merge fork summary into parent
7. `POST /api/streams/:sessionKey/merge-draft` -> optional provider draft generation

Rules:
1. REST mutation success must be followed by matching WebSocket event broadcast.
2. Client treats WebSocket event as final truth for ordering/topology.
3. Idempotency keys are required for fork/merge create commands.

### 9.3 Consistency and replay

1. `treeVersion` is monotonic per user account.
2. On reconnect, if local `treeVersion` is stale or unknown, server sends `stream_snapshot`.
3. If event gap is detected, client requests `GET /api/streams` and replaces local tree.

## 10. Fork and Merge Semantics

### 10.1 Fork semantics

1. Fork history includes all messages up to and including `forkOriginMessageId`.
2. Messages added to parent after fork do not appear in child.
3. Child messages do not appear in parent unless merged.
4. Nested forks are allowed (fork of fork).
5. Forking from missing/deleted message is invalid and returns `not_found`.

### 10.2 Merge semantics

1. Merge target is direct parent in v1.
2. Merge creates one parent message containing user-approved summary.
3. Merge metadata links parent and child for provenance.
4. Merge is repeatable; each merge is separate summary message.
5. Merge does not auto-delete fork unless user explicitly chooses delete.

## 11. Edge Cases and Failure Handling

1. Multiple forks from different messages in same parent:
   - Each source message shows its own anchored indicator.
   - No global floating branch badge.
2. Multiple forks from same message:
   - Indicator count shown.
   - Tap opens chooser.
3. Parent message not currently loaded (virtualized history):
   - Indicator appears when message is materialized.
   - Stream manager still lists forks immediately.
4. Source message was filtered out by "my messages only":
   - Fork indicator follows message visibility rules.
   - Fork still accessible via stream manager and child identity indicator.
5. Fork request while source assistant message is streaming:
   - Reject with conflict; user can retry after final message.
6. Deleting parent with active children:
   - Reject in v1 (non-leaf delete blocked).
7. Merge while parent deleted/archived:
   - Reject with conflict and show actionable error.
8. Cross-device concurrent rename/delete/fork:
   - Higher `treeVersion` wins; stale commands return conflict.
9. Offline fork/merge command retries:
   - Use idempotency key; safe to retry after reconnect.
10. Replay truncation on reconnect:
    - If message replay truncates, client keeps topology via latest stream snapshot and marks potential message gap.

## 12. Migration and Compatibility

1. Existing sessions become root nodes (`parentId: null`).
2. No breaking change to session-key routing semantics.
3. Legacy clients without stream-tree support should continue using default stream only; provider may gate multi-stream capability by protocol version.

## 13. Acceptance Criteria

1. Fork indicator is attached to source message, not floating UI chrome.
2. Tapping source-message fork indicator pages to correct fork.
3. Every fork shows top origin bubble with reason/context and jump-to-source action.
4. Every fork shows persistent identity indicator with parent navigation.
5. Page ordering matches rules for add and fork insertion.
6. Merge posts exactly one summary message into parent.
7. Tree/topology remains consistent across reconnect and multi-device use.
