# Clawline Multi-User & Admin Channel Spec

**Author:** CLU  
**Date:** 2026-01-16  
**Status:** Draft v2 - Simplified for Family Use

## Context

Clawline runs on a **private Tailscale network** for **~5 trusted family members**. This is not a public service. The security model assumes mutual trust.

## Goals

1. Any family member can pair and start chatting immediately
2. Admin users (Flynn) can access the main agent session from Clawline
3. Everyone gets their own personal conversation space
4. Simple, no friction

## User Model

### Regular User
- `isAdmin: false`
- One chat channel (personal, isolated session)
- Can't see other users' conversations

### Admin User  
- `isAdmin: true`
- **Two chat channels in the app**:
  - **Personal** — their own isolated conversation
  - **Admin** — shared with main session (Discord, etc.)

**Note:** `isAdmin` is **per-user**, not per-device. All devices belonging to an admin user get admin access.

## Pairing Flow

1. Device requests pairing
2. **Auto-approved** immediately with `isAdmin: false`
3. If Flynn wants someone to be admin, he tells CLU → CLU sets `isAdmin: true`

No pending queue. No approval workflow. Family network = trust.

## Message Routing

### Message Format
```json
{
  "type": "message",
  "channelType": "personal" | "admin",
  "content": "..."
}
```

### Routing Logic
- `channelType: "personal"` → isolated session per user
- `channelType: "admin"` (requires `isAdmin: true`) → main agent session
- **Missing `channelType`** → defaults to `"personal"` (backward compatibility)

### Session Keys
- Personal: `agent:main:clawline:dm:{userId}`
- Admin: routes to `agent:main:main`

### Admin Channel Buffering
If the main session is unavailable when an admin sends to the admin channel, **buffer the message** and deliver when the session comes back. Don't drop messages.

## iOS App Changes

### For Regular Users
- Single chat view (personal channel)
- No indication admin channel exists

### For Admin Users
- Tab bar or segmented control: **Personal | Admin**
- Visual differentiation (different accent color for admin)
- Messages route to correct channel based on active tab

### Protocol
- Outbound messages include `channelType`
- Responses tagged with same `channelType` for routing to correct tab

### Admin Status Sync
On WebSocket connect, server sends `user_info` with current admin status:
```json
{
  "type": "user_info",
  "userId": "flynn",
  "isAdmin": true
}
```
App compares to cached value and updates UI (show/hide admin tab). Changes take effect on next app open.

## Implementation

### Provider (clawdbot)
1. Remove pending queue logic — auto-approve all pairings
2. Add `channelType` to message protocol
3. Route `admin` channel to main session (integrate with SessionManager)
4. Keep personal channel as isolated sessions

### iOS App
1. Check `isAdmin` from JWT token
2. Show channel switcher if admin
3. Include `channelType` in messages
4. Display responses in matching tab

### Admin Promotion
- CLU edits `allowlist.json` to set `isAdmin: true`
- Or: add a `/clawline admin grant {userId}` command

## Open Questions

1. Should admin channel show full main session history, or just from when they switch to it?
2. Channel switcher UI: tabs, segmented control, or swipe?
3. Should there be visual confirmation when switching channels to prevent accidental sends?

## Non-Goals (for now)

- Public internet access
- Rate limiting / abuse prevention  
- Complex audit trails
- Multi-provider federation
- E2E encryption (Tailscale handles transport)

---

Keep it simple. It's family.
