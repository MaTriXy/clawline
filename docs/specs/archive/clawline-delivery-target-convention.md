# Delivery Target Convention: OriginatingTo + lastTo

## How they work (from investigation + provider source audit)

### OriginatingTo
- **What:** Per-message "reply routing target" — set server-side by the provider on each inbound message.
- **Direction:** Inbound (set when message arrives).
- **Scope:** Transient — lives in the message context, not persisted directly.
- **Used by:** Reply routing (`route-reply.ts`), session metadata (`origin.to`), and as seed for `lastTo`.
- **Key rule:** Core uses `ctx.OriginatingTo || ctx.To || baseEntry?.lastTo` to derive `lastTo` for the session.

### lastTo
- **What:** Persisted "most recent delivery target" for a session (paired with `lastChannel`, `lastAccountId`).
- **Direction:** Outbound (read when agent needs to deliver a reply).
- **Scope:** Per-session, written to session store.
- **Set by:** `recordInboundSession({ updateLastRoute })` or implicitly from `OriginatingTo`.
- **Used by:** `resolveSessionDeliveryTarget()` → `resolveAgentDeliveryPlan()` for implicit outbound routing.

### deliveryContext
- **What:** Normalized `{ channel, to, accountId, threadId }` — the structured version of `lastTo` + `lastChannel`.
- **Stored on:** Session entry. `lastTo`/`lastChannel` are the flattened form.

### The bridge
`OriginatingTo` (per-message, inbound) → writes to → `lastTo` (per-session, persisted) → read for → outbound delivery.

---

## Convention by provider (from source)

### Discord

| Chat type | OriginatingTo | updateLastRoute.to | Notes |
|---|---|---|---|
| DM | `channel:<channelId>` | `user:<authorId>` | OriginatingTo uses channel format even for DMs; updateLastRoute uses user format for main session routing |
| Guild channel | `channel:<channelId>` | *(not set)* | Non-DMs don't update lastRoute |
| Thread | `channel:<threadId>` | *(not set)* | Thread ID replaces channel ID |

**Pattern:** `OriginatingTo` = where to reply (always `channel:<id>`). `updateLastRoute.to` = who to route to on the shared main session (only for DMs, `user:<id>`).

### Telegram

| Chat type | OriginatingTo | updateLastRoute.to | Notes |
|---|---|---|---|
| DM | `telegram:<chatId>` | `<chatId>` (raw string) | OriginatingTo has prefix; updateLastRoute is raw |
| Group | `telegram:<chatId>` | *(not set)* | Groups don't update lastRoute |
| Forum topic | `telegram:<chatId>` | *(not set)* | Thread ID carried separately in `MessageThreadId` |

**Pattern:** `OriginatingTo` = prefixed `telegram:<id>`. `updateLastRoute.to` = raw ID, DMs only.

---

## Key rules (from both investigation + provider)

1. **`OriginatingTo` is always set** — every inbound message gets one, server-side.
2. **`updateLastRoute` is only set for DMs** — groups/channels don't update it (Discord and Telegram both skip it for non-DMs).
3. **`updateLastRoute` targets the MAIN session key** — it updates `agent:main:main`'s delivery context so implicit sends from the shared session go to the right place.
4. **The value formats differ between the two fields** — `OriginatingTo` often has a prefix (`channel:`, `telegram:`), while `updateLastRoute.to` uses a different format (`user:<id>`, raw `<chatId>`).

---

## What Clawline currently does (from investigation Sub-Investigation 5)

```
OriginatingTo: "flynn:main"    ← hardcoded for ALL messages (admin + personal)
updateLastRoute.to: "flynn:main"  ← same value, via recordInboundSession
```

**Bug:** Both admin and personal set identical values. Core can't distinguish where to deliver.

---

## Proposed Clawline convention (following Discord/Telegram pattern)

The convention is:
- **`OriginatingTo`** = channel-prefixed delivery target (where to reply to THIS message)
- **`updateLastRoute.to`** = user-level routing target on the shared main session (DMs only)

Applying to Clawline's three streams:

### Main stream
- **OriginatingTo:** `clawline:<userId>:main` (e.g. `clawline:flynn:main`)
- **updateLastRoute:** *(not set)* — Main is per-user, not the shared session. No need to update main session routing.

### DM stream (when dmScope ≠ main)
- **OriginatingTo:** `clawline:<userId>:dm` (e.g. `clawline:flynn:dm`)
- **updateLastRoute.to:** `<userId>:dm` (e.g. `flynn:dm`) — updates `agent:main:main` so implicit sends from the shared session can route back to this user's DM.

### Global DM stream (admin only, targets agent:main:main)
- **OriginatingTo:** `clawline:<userId>:global` (e.g. `clawline:flynn:global`)
- **updateLastRoute.to:** `<userId>:global` (e.g. `flynn:global`) — updates main session routing to point back to this admin's Global DM surface.

### When dmScope = main (DM IS the global session)
- **OriginatingTo:** `clawline:<userId>:dm` (e.g. `clawline:flynn:dm`)
- **updateLastRoute.to:** `<userId>:dm` — same as non-global DM, because in this scope the DM targets agent:main:main directly.

---

## Summary table

| Stream | OriginatingTo | updateLastRoute.to | updateLastRoute targets |
|---|---|---|---|
| Main | `clawline:<userId>:main` | *(not set)* | — |
| DM (dmScope ≠ main) | `clawline:<userId>:dm` | `<userId>:dm` | `agent:main:main` |
| Global DM (admin) | `clawline:<userId>:global` | `<userId>:global` | `agent:main:main` |
| DM (dmScope = main) | `clawline:<userId>:dm` | `<userId>:dm` | `agent:main:main` |

---

## Outbound resolution

When the agent produces output for a session, core resolves delivery:
1. Reads `deliveryContext` from session entry → gets `{ channel: "clawline", to: "<userId>:<stream>" }`
2. Passes to Clawline provider
3. Provider parses the `to` field to determine which stream/websocket to deliver to
4. Provider looks up connected client by `userId`, delivers to correct stream

**The provider's outbound path must parse the `to` suffix** (`:main`, `:dm`, `:global`) to route to the correct chat view on the client.
