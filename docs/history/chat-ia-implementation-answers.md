# Chat IA Implementation Questions - Answers

Answers based on routing investigations, invariants, and design decisions from 2026-02-04 through 2026-02-06.

---

## Architectural Boundaries (Critical)

The following boundaries define what identifiers are used where. Violations of these boundaries break invariants N3 and N7.

### Provider-Internal (Never Exposed to Client)

**Delivery targets:** `<userId>:<streamSuffix>` format
- Examples: `flynn:main`, `flynn:dm`, `flynn:global`
- Suffixes: `:main`, `:dm`, `:global`
- Used in: `lastTo`, `OriginatingTo`, `updateLastRoute.to`, internal authorization logic, logging
- Purpose: Provider parses suffix to determine authorization (should this device receive this message?)
- **MUST NOT appear in wire protocol to client**

**Error responses:** May include human-readable references to stream concepts in error messages, but MUST NOT include delivery targets or stream labels as structured error fields

**Logging and diagnostics:** Provider-internal only; may include delivery targets, `OriginatingTo`, session keys, and other routing metadata

### Wire Protocol (Provider ↔ Client)

**Session keys ONLY** - no delivery targets, no stream labels, no suffixes
- Inbound (client → provider): client sends `sessionKey` field
- Outbound (provider → client): provider sends `sessionKey` field
- Handshake (provider → client): provider sends array of session keys
- **Client never sees `:main`, `:dm`, `:global` suffixes**
- **Client never sees `main`, `dm`, `global` as routing labels or object keys**
- Exception: `dmScope` and `isAdmin` are exposed to client for visibility logic (not routing identifiers)

### Client-Internal (Never Sent to Provider)

**Session keys mapped to chat views locally**
- Client receives session keys from handshake
- Client determines which session key corresponds to which chat view (Main/DM/Global DM)
- Mapping logic: client-side implementation detail, not part of protocol

### Core (OpenClaw Session Store)

**Session keys are canonical routing identifiers**
- `sessionKey` field is the authoritative identifier
- `deliveryContext.channel` and `deliveryContext.to` contain delivery targets (provider format)
- Core does not interpret delivery target suffixes - those are provider-specific

---

## 1) Session provisioning handshake

**Q1: Connect sequence and message shapes?**

**A:** Part of auth/connect ack. Provider returns:
```typescript
{
  success: true,
  userId: "flynn",
  isAdmin: true,
  dmScope: string,  // e.g., "main", "per-peer" - for client visibility logic
  sessionKeys: string[]  // Array of session keys client is allowed to access
}
```

**Provider logic:**
1. Always include Main session: `agent:main:clawline:{userId}:main`
2. If `dmScope !== "main"`, include DM session: resolved via `resolveAgentRoute`
3. If `isAdmin === true`, include Global DM session: `agent:main:main`

**Client visibility logic:**
- Main → always show
- DM → show if `dmScope !== "main"` OR `isAdmin === true`
- Global DM → show only if `isAdmin === true`
- Deduplicate: if two session keys are identical, show as one chat

Client maps session keys to chat views locally. No stream labels on the wire.

**Q2: What does client send on first message?**

**A:** Client sends `sessionKey` (from connect ack). No stream token (N7 violation). For brand-new session where client has no cache, it requests session info via connect first.

**Q3: How does provider derive sessionKey when client missing?**

**A:** Provider calls `resolveAgentRoute(userId, accountId, channel)`. This is allowed - it's using userId (authenticated) + channel context, not constructing keys from patterns.

**Q4: Session keys stable across reconnects?**

**A:** Yes. dmScope is server config, not runtime. Keys don't change unless server config changes. If dmScope changes, provider must push new session info to connected clients (TBD: wire protocol for this).

---

## 2) Delivery target format

**Q5: Where is `<userId>:<streamSuffix>` format defined?**

**A:** Should live in `src/clawline/routing.ts` as `ClawlineDeliveryTarget` class (already exists per 2026-02-04 canonicalization work). Authoritative parser there.

**Q6: Exact three suffixes and semantics?**

| Suffix | UI Surface | Session Key (when dmScope=main) | Session Key (when dmScope≠main) |
|--------|------------|--------------------------------|--------------------------------|
| `:main` | Admin Main | `agent:main:clawline:flynn:main` | `agent:main:clawline:flynn:main` |
| `:dm` | Personal DM | `agent:main:main` | `agent:main:dm:flynn` (or per-channel/account variants) |
| `:global` | Global DM (admin only) | `agent:main:main` | `agent:main:main` |

**Q7: OriginatingTo for non-admin DM when dmScope=main?**

**A:** Non-admins MUST NOT send DM-targeted messages when dmScope=main. Provider rejects with 403 Forbidden. Error: "DM access restricted to administrators when dmScope=main (N8)".

**Q8: Outbound authorization condition?**

**A:** Provider checks:
```typescript
if (suffix === 'global' && !socket.isAdmin) return skip;
if (suffix === 'dm' && dmScope === 'main' && !socket.isAdmin) return skip;
if (socket.userId !== targetUserId) return skip;
// else: deliver
```

**Q9: Outbound sessionKey mapping?**

| deliveryContext.to | sessionKey sent to client |
|-------------------|--------------------------|
| `flynn:main` | `agent:main:clawline:flynn:main` |
| `flynn:dm` | Resolved DM key |
| `flynn:global` | `agent:main:main` |

Provider resolves session keys at connect time and caches them. For outbound delivery, provider reads `deliveryContext.to` suffix for authorization, then sends the corresponding session key to the client.

**Q10: Definitive mapping table?**

See **Canonical Reference Table** below.

---

## 3) recordInboundSession requirements

**Q11: Call placement?**

**A:** After auth + message validation, before dispatching to agent. If SQLite write fails, still call recordInboundSession - core store is separate. Rationale: core needs session entry even if local cache fails.

**Q12: updateLastRoute values per stream?**

| Stream | updateLastRoute sessionKey | updateLastRoute.to |
|--------|---------------------------|-------------------|
| Main | `undefined` (no cross-session write) | N/A |
| DM | `agent:main:main` | `flynn:dm` |
| Global DM | `undefined` (message lands in main already) | N/A |

**Q13: OriginatingTo → lastTo overwrite?**

**A:** Yes, desired. Every inbound message to a Clawline session overwrites that session's `lastTo` with `OriginatingTo` value via implicit `initSessionState` write. This is how replies know where to route. Channel-scoped sessions (`agent:main:clawline:flynn:main`) should have this behavior.

---

## 4) Announce routing

**Q14: Required fields for announce routing?**

**A:** Parent session entry must have:
- `OriginatingChannel` = "clawline"
- `OriginatingTo` = `<userId>:<suffix>`
- Session entry must exist in core store (via recordInboundSession)

**Q15: Failure path when session missing?**

**A:** Core creates orphan session with random ID, no context. Sub-agent result goes nowhere or wrong place. Provider should log after recordInboundSession to verify core accepted it.

---

## 5) Multi-device

**Q16: Multi-device delivery?**

**A:** Yes - outbound goes to all connected devices for `userId` that pass authorization (Q8). All devices write same `OriginatingTo`, so last-write-wins on `lastTo`. This is acceptable (matches Discord behavior).

**Q17: Admin streams to non-admin devices?**

**A:** Authorization is per-device. If user has both admin and non-admin devices connected:
- Global DM (`:global`) → only admin devices
- DM when dmScope=main → only admin devices
- Main → all devices

Client device stores `isAdmin` flag from connect ack.

---

## 6) Error semantics

**Q18: Error codes for violations?**

| Violation | HTTP-style code | Message |
|-----------|----------------|---------|
| N8: non-admin DM when dmScope=main | 403 | "DM access restricted to administrators (dmScope=main)" |
| Unknown/invalid sessionKey | 400 | "Invalid session key" |
| Missing session provisioning | 401 | "Session info not provisioned - reconnect required" |

**Q19: Required logging fields?**

```typescript
{
  direction: "inbound" | "outbound",
  sessionKey: string,
  OriginatingTo?: string,
  deliveryTarget?: string,  // parsed from OriginatingTo
  userId: string,
  isAdmin: boolean,
  dmScope: string,
  outboundSessionKey?: string,  // for outbound only
  deviceId: string
}
```

---

## 7) Canonical Reference Table

### Inbound (Client → Provider → Core)

| Stream | sessionKey | OriginatingTo | updateLastRoute | Notes |
|--------|-----------|--------------|----------------|-------|
| **Main** | `agent:main:clawline:flynn:main` | `flynn:main` | `undefined` | Channel-scoped, no cross-session write |
| **DM** (dmScope=main) | `agent:main:main` | `flynn:dm` | `undefined` | Message lands in main already, no updateLastRoute needed |
| **DM** (dmScope≠main) | `agent:main:dm:flynn` (or variant) | `flynn:dm` | `{ sessionKey: "agent:main:main", to: "flynn:dm" }` | Writes to personal DM session, updates main's lastTo |
| **Global DM** | `agent:main:main` | `flynn:global` | `undefined` | Admin only, lands in main |

### Outbound (Core → Provider → Client)

| deliveryContext.to | sessionKey sent to client | Authorization | Notes |
|-------------------|--------------------------|--------------|-------|
| `flynn:main` | `agent:main:clawline:flynn:main` | `userId=flynn` | All devices |
| `flynn:dm` (dmScope=main) | `agent:main:main` | `userId=flynn && isAdmin` | Admin devices only |
| `flynn:dm` (dmScope≠main) | Resolved DM key | `userId=flynn` | All devices |
| `flynn:global` | `agent:main:main` | `userId=flynn && isAdmin` | Admin devices only |

### Bootstrap (Connect/Auth Response)

```typescript
interface ConnectAck {
  success: true;
  userId: string;
  isAdmin: boolean;
  dmScope: string;  // For client visibility logic
  sessionKeys: string[];  // Session keys client is allowed to access
}
```

**Example response (dmScope="main", isAdmin=true):**
```typescript
{
  success: true,
  userId: "flynn",
  isAdmin: true,
  dmScope: "main",
  sessionKeys: [
    "agent:main:clawline:flynn:main",  // Main
    "agent:main:main"  // Global DM (admin only; also serves as DM when dmScope=main)
  ]
}
```

**Example response (dmScope="per-peer", isAdmin=false):**
```typescript
{
  success: true,
  userId: "flynn",
  isAdmin: false,
  dmScope: "per-peer",
  sessionKeys: [
    "agent:main:clawline:flynn:main",  // Main
    "agent:main:dm:flynn"  // Personal DM
  ]
}
```

---

## Open Questions (Need Flynn Decision)

None - all 20 questions answered from prior investigations and design decisions.
