# Clawline Chat Information Architecture

**Status:** Complete (2026-02-07)  
**Last updated:** 2026-02-07

---

## Overview

This document defines how chats are organized and presented in the Clawline iOS/visionOS app, and how each UI element maps to OpenClaw's session-based architecture.

**Scope:**
- What appears in the Clawline chat list
- How admin vs personal spaces differ
- How dmScope configuration affects visible streams
- Session key mappings for each stream
- Routing and delivery behavior

**Non-scope:**
- Visual design / layout polish
- Notifications UX
- Search implementation
- OpenClaw core implementation details (see `history/` for point-in-time implementation references)

---

## Core Principles

### 1. Session keys are the canonical routing identifiers
Every chat in Clawline maps to a unique OpenClaw session key. Session keys determine conversation history, context, agent configuration, and routing. No parallel routing identifiers exist.

### 2. dmScope is binary: global vs not-global
OpenClaw's `session.dmScope` configuration determines DM session scoping:
- **Global** (`dmScope=main`): all DMs share one session (`agent:main:main`)
- **Not-global** (any other value): each user gets their own DM session

Clawline treats all non-global scopes identically in the UI. The concrete session key format varies, but the UX is the same.

### 3. DM session keys are opaque to the client
Clawline never constructs DM session keys. The provider receives the resolved key from OpenClaw core and passes it to the client. DM key format changes with dmScope configuration — the client doesn't care.

### 4. One chat = one session
Each chat in the UI corresponds to exactly one OpenClaw session key. No aliases, no shared sessions across multiple chat list entries.

### 5. Delivery target ≠ session identity
- **Session key** = conversation identity (history, context, agent)
- **Delivery target** = where to route messages on the wire (`userId:streamSuffix`)

These are separate concepts. The delivery target format (`flynn:main`, `flynn:dm`) is a wire protocol detail, not part of the session key.

---

## The Three Streams

Clawline presents up to three chat streams, depending on user role and dmScope configuration.

### 1. Main Stream
**Always visible to everyone.**

The user's primary chat surface. Single-channel (only Clawline writes here).

**Session key:** `agent:main:clawline:<userId>:main`

**Example:** Flynn's Main stream is `agent:main:clawline:flynn:main`

### 2. Personal DM Stream
**Visible when dmScope is not-global.**

Each user's isolated DM session. Non-admins only see this when dmScope creates per-user isolation.

**Session key:** Varies by dmScope (see mapping table below). Always resolved by core.

**Behavior:** Whether this is single-channel or multi-channel depends on dmScope:
- `per-peer` → multi-channel (all channels write here)
- `per-channel-peer` → single-channel (Clawline only)
- `per-account-channel-peer` → single-channel (Clawline only)

### 3. Global DM Stream
**Always visible to admins.**

The shared operator session where multi-channel messages converge. Multi-channel by design — Discord, Telegram, Clawline all write here.

**Session key:** `agent:main:main`

**Special case (dmScope=main, admin):** When dmScope is `main`, the Personal DM session key IS `agent:main:main` (same as Global DM). Admins see one "Global DM" chat, not two.

---

## Visibility Matrix

| dmScope | Non-admin sees | Admin sees |
|---|---|---|
| `main` | Main only | Main + Global DM |
| `per-peer` | Main + Personal DM | Main + Personal DM + Global DM |
| `per-channel-peer` | Main + Personal DM | Main + Personal DM + Global DM |
| `per-account-channel-peer` | Main + Personal DM | Main + Personal DM + Global DM |

**Key insight:** All non-global scopes behave identically in the UI. The only difference is the backing session key.

---

## Session Key Mapping by dmScope

The concrete session key backing each stream depends on the configured dmScope. Clawline receives these from the provider at connect time — it never constructs them (except Main, which is always the same).

### dmScope = `main` (global)

| Stream | Session key | Channel behavior |
|---|---|---|
| Main | `agent:main:clawline:<userId>:main` | Single-channel (Clawline only) |
| Personal DM | *(hidden for non-admins)* | N/A |
| Global DM | `agent:main:main` | Multi-channel (admin only) |

### dmScope = `per-peer`

| Stream | Session key | Channel behavior |
|---|---|---|
| Main | `agent:main:clawline:<userId>:main` | Single-channel |
| Personal DM | `agent:main:dm:<userId>` | Multi-channel (all channels write here) |
| Global DM | `agent:main:main` | Multi-channel (admin only) |

### dmScope = `per-channel-peer`

| Stream | Session key | Channel behavior |
|---|---|---|
| Main | `agent:main:clawline:<userId>:main` | Single-channel |
| Personal DM | `agent:main:clawline:dm:<userId>` | Single-channel (Clawline only) |
| Global DM | `agent:main:main` | Multi-channel (admin only) |

### dmScope = `per-account-channel-peer`

| Stream | Session key | Channel behavior |
|---|---|---|
| Main | `agent:main:clawline:<userId>:main` | Single-channel |
| Personal DM | `agent:main:clawline:default:dm:<userId>` | Single-channel (Clawline only) |
| Global DM | `agent:main:main` | Multi-channel (admin only) |

**Implementation note:** The Main stream key format is constant across all dmScope values. Only DM keys vary.

---

## Delivery Targets

Messages routing between client and provider use a delivery target format separate from session keys.

**Format:** `<userId>:<streamSuffix>`

| Stream | Delivery target | Example |
|---|---|---|
| Main | `<userId>:main` | `flynn:main` |
| Personal DM | `<userId>:dm` | `flynn:dm` |
| Global DM | `<userId>:global` | `flynn:global` |

**These are NOT session keys.** They are wire protocol addresses. The `:main`/`:dm`/`:global` suffix tells the provider which chat view to deliver to.

**Inbound:** Client includes delivery target in message payload. Provider uses it to determine `OriginatingTo`.

**Outbound:** Provider parses session's delivery context and sends messages to the correct stream.

---

## Chat Storage

All chat history (Main, DM, Global DM) is stored in the Clawline iOS app's SQLite database. The app does NOT read OpenClaw's JSONL session logs. Storage mechanism is identical across all streams.

**Restore on launch:** App restores the last-viewed stream automatically (existing session restore pattern).

---

## Future Surfaces

### Groups (v2)
When OpenClaw supports multi-user group sessions with stable groupIds, Clawline will add group chat views. Not part of initial implementation.

### System Chat (optional)
Potential future surface for device pairing notifications, warnings, system-level alerts. Not prioritized.

---

## Key Architectural Decisions

### Chat list structure
Each stream appears as a **separate chat entry** in the list. No segmented controls, no unified inbox. Main, DM, and Global DM are distinct rows.

### Session identity
The provider creates the Main stream session (`agent:main:clawline:<userId>:main`) on first connect. Core tracks it like any other session. No special "Clawline-managed" flag.

### No projects
Clawline does not implement a projects/workspaces concept. The three streams (Main, DM, Global DM) plus future groups are the only organizational surfaces.

### Connect handshake
The provider's connect/auth handshake returns:
- **User identity** (userId, roles)
- **dmScope** (for client-side visibility logic)
- **Resolved session keys** for each visible stream

The client uses these session keys for all subsequent message routing.

---

## Implementation References

Detailed OpenClaw core implementation notes (routing logic, code paths, function signatures, historical bugs) are preserved in `/Users/mike/shared-workspace/clawline/history/`:

- **Implementation Q&A** — 20 questions answered during provider implementation
- **Reality check** — Spec-vs-code audit findings
- **Routing investigation** — Deep dive on alert routing bugs
- **Original verbose spec** — Point-in-time snapshot with all internal details

These documents capture our understanding at the time of implementation (Feb 2026). OpenClaw core may change; the IA described in this document remains stable.

---

## Summary

**Three streams:**
1. Main (everyone, always)
2. Personal DM (non-admins when dmScope ≠ main)
3. Global DM (admins, always)

**Session keys:**
- Main: always `agent:main:clawline:<userId>:main`
- DM: varies by dmScope, resolved by core
- Global DM: always `agent:main:main`

**Delivery targets:**
- Wire protocol format: `<userId>:main|dm|global`
- Separate from session keys

**Storage:**
- All streams stored in Clawline SQLite
- No JSONL reads

**Visibility:**
- Non-admins see Main (+ DM if dmScope ≠ main)
- Admins see everything
