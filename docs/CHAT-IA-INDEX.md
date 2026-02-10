# Chat Information Architecture - Complete File Index

**Project status:** Complete (2026-02-07)  
**Provider deployed:** `origin/main @ af3e2a28a` (2026-02-06 23:47 PST)  
**Client:** Verified working (2026-02-07)

---

## Current Documentation

### Primary Specification
**`specs/chat-information-architecture.md`** (8.8K)
- The three-stream model (Main, DM, Global DM)
- Visibility rules and session key mappings
- Core architectural principles
- Does NOT contain OpenClaw core internals (those are in history/)

### Related Specifications
**`specs/clawline-delivery-target-convention.md`** (5.7K)
- Wire protocol format for delivery targets
- `userId:streamSuffix` convention
- Enforced by `ClawlineDeliveryTarget` class

**`specs/clawline-multiuser-spec.md`** (3.5K)
- Multi-user authentication and authorization
- Admin vs non-admin capabilities

**`specs/clawline-message-flow.html`** (11K)
- Visual diagram of message routing
- Inbound/outbound flow visualization

---

## Implementation History (Point-in-Time References)

All files in `history/` are **not maintained**. They capture our understanding at implementation time (Feb 2026). OpenClaw core may drift.

### Original Verbose Specification
**`history/chat-information-architecture-verbose-2026-02-06.md`** (43K)
- Full spec with OpenClaw core implementation details
- Code paths, function signatures, line numbers
- Glossary of routing concepts (OriginatingTo, lastTo, updateLastRoute, etc.)
- Negative invariants (bugs we fixed)
- Dangerous assumptions myth-buster table

### Implementation Q&A
**`history/chat-ia-implementation-questions.md`** (7.7K)
- 20 questions raised by clawline-provider agent during spec review
- Edge cases, session lifecycle, dmScope behavior

**`history/chat-ia-implementation-answers.md`** (11K)
- Answers to all 20 questions
- Code references to OpenClaw core
- Clarifications on routing, delivery, and session creation

### Validation
**`history/chat-ia-reality-check.md`** (6.6K)
- Spec-vs-code audit after initial implementation
- Identified drift between spec and actual behavior
- All findings addressed before final deployment

### Root Cause Investigation
**`history/2026-02-04-message-routing-investigation.md`** (20K)
- Deep investigation into alert routing bugs that preceded Chat IA work
- Why we needed the three-stream architecture
- Sub-investigations on:
  - Alert misrouting (messages landing in wrong stream)
  - Missing recordInboundSession calls
  - channelType routing identifier removal
  - Cron vs alert pathway differences

### Index
**`history/README.md`** (2K)
- Explains purpose of history folder
- Lists all historical documents
- Clarifies these are reference-only, not maintained

---

## Related Clawline Documentation (Not Chat IA Specific)

### Architecture
**`architecture.md`**
- Overall Clawline architecture (not Chat IA specific)

**`provider-architecture.md`**
- Clawline provider internals

**`ios-architecture.md`**
- iOS client architecture

### Implementation Notes
**`implementation-notes/image-send-bug-client.md`**
**`implementation-notes/image-send-bug-server.md`**
**`implementation-notes/keyboard-handling.md`**
- Bug investigations and fixes (not Chat IA)

### Other Specs
**`ios-flow-layout-rules.md`**
**`ios-provider-connection.md`**
**`provider-testing.md`**
**`siri-intent.md`**
- Various iOS/provider specs

### Investigations
**`investigations/clawline-busy-queue-investigation.md`**
**`investigations/clawline-extension-consolidation.md`**
- Other investigations (not Chat IA)

### Above Bar
**`above-bar-gap-analysis.md`**
- Quality bar analysis

---

## File Locations Summary

### Active/Current
```
specs/
├── chat-information-architecture.md          ← PRIMARY SPEC
├── clawline-delivery-target-convention.md
├── clawline-multiuser-spec.md
└── clawline-message-flow.html
```

### Historical Reference
```
history/
├── README.md                                  ← Explains history folder
├── chat-information-architecture-verbose-2026-02-06.md
├── chat-ia-implementation-questions.md
├── chat-ia-implementation-answers.md
├── chat-ia-reality-check.md
└── 2026-02-04-message-routing-investigation.md
```

---

## What to Read When

### "I need to understand Chat IA"
Start here: **`specs/chat-information-architecture.md`**

### "I'm implementing a feature that touches routing"
1. Read **`specs/chat-information-architecture.md`**
2. Check **`specs/clawline-delivery-target-convention.md`**
3. If you need to understand WHY certain decisions were made, see history/

### "I'm debugging a routing issue"
1. Read **`specs/chat-information-architecture.md`** first (understand current state)
2. Check **`history/2026-02-04-message-routing-investigation.md`** (past bugs)
3. Check **`history/chat-ia-reality-check.md`** (spec-vs-code drift issues)

### "I need to know exactly how OpenClaw core routing works"
See **`history/chat-information-architecture-verbose-2026-02-06.md`**
⚠️ **Warning:** Core internals may have drifted. This is a point-in-time snapshot.

---

## Maintenance

### Current spec (`specs/chat-information-architecture.md`)
**Update when:**
- Clawline IA changes (new streams, different visibility rules, etc.)
- Session key mapping conventions change
- Delivery target format changes

**Do NOT update when:**
- OpenClaw core internals change (that's what history/ is for)

### Historical docs (`history/*`)
**Never update.** These are snapshots. If core behavior has meaningfully changed, create a NEW history document with a new date.

---

## Quick Reference

| Need | Document |
|---|---|
| High-level IA overview | `specs/chat-information-architecture.md` |
| Delivery target format | `specs/clawline-delivery-target-convention.md` |
| Session key examples | `specs/chat-information-architecture.md` (Session Key Mapping) |
| Visibility rules | `specs/chat-information-architecture.md` (Visibility Matrix) |
| Why we have 3 streams | `history/2026-02-04-message-routing-investigation.md` |
| Core routing internals | `history/chat-information-architecture-verbose-2026-02-06.md` |
| Implementation Q&A | `history/chat-ia-implementation-answers.md` |

---

**Index created:** 2026-02-07  
**Purpose:** Track all Chat IA documentation in one place
