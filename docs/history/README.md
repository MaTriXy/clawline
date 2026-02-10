# Chat IA Implementation History

This folder contains point-in-time snapshots of the Chat Information Architecture implementation work (February 2026).

## Status: Reference Only

These documents capture our understanding of OpenClaw core internals at the time of Chat IA implementation. **They are not maintained.** OpenClaw core may change; implementation details may drift.

Use these for:
- Historical reference
- Understanding past architectural decisions
- Debugging similar routing issues

Do NOT use these as current implementation documentation.

---

## Documents

### chat-ia-implementation-questions.md
20 implementation questions raised by the clawline-provider agent during spec review. Covers routing edge cases, session creation, dmScope behavior, and provider responsibilities.

### chat-ia-implementation-answers.md
Answers to all 20 questions. Includes code references, clarifications on session lifecycle, updateLastRoute behavior, and delivery target parsing.

### chat-ia-reality-check.md
Spec-vs-code audit performed after initial provider implementation. Identified drift between spec and actual code behavior. All findings addressed before final deployment.

### 2026-02-04-message-routing-investigation.md
Deep investigation into alert routing bugs that preceded Chat IA work. Documents the root causes that led to the three-stream architecture. Includes sub-investigations on:
- Alert misrouting (N1, N2 violations)
- Missing recordInboundSession calls
- channelType routing identifier issues
- Cron vs alert pathway differences

---

## Current Documentation

For the current Chat IA specification, see:
**`/Users/mike/shared-workspace/clawline/specs/chat-information-architecture.md`**

The current spec describes WHAT the architecture is (three streams, visibility rules, session mappings) without diving into OpenClaw core implementation internals.

---

**Archived:** 2026-02-07  
**Reason:** Consolidation — separated IA architecture from implementation details
