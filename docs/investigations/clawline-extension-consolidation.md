# Clawline Extension Consolidation Plan

**Goal:** Move all Clawline-specific content into `extensions/clawline/` so:
1. Skills auto-register when Clawline is enabled (via plugin manifest)
2. Agent guidance (AGENTS.md, CLAUDE.md) lives with the code
3. Fork divergence vs upstream is minimal and localized

## Current State

### Skills (in `skills/`)
All of these are **our contributions** (upstream has none):

| Skill | Purpose |
|-------|---------|
| `clawline-alert-overlay` | Alert instructions overlay |
| `clawline-allowlist` | Inspect allowlist/pending/denylist |
| `clawline-gateway-ops` | Restart, health checks, rate limits |
| `clawline-media` | Locate/retrieve uploaded assets |
| `clawline-pairing` | Approve/deny pending devices |

**Missing:**
- No skill for the new `webRootPath` feature (serves static files at `/www`)
- Device management operations are split across `allowlist` and `pairing` — should consolidate

### Agent Guidance (in `src/clawline/`)
- `AGENTS.md` - Agent guidelines (channel mapping, upstream merge protocol)
- `CLAUDE.md` - Module guidelines (same content, slightly different format)

### Extension (in `extensions/clawline/`)
- `index.ts` - Plugin registration (channel + service)
- `openclaw.plugin.json` - Manifest (no skills listed)
- `src/` - Channel adapter, outbound, onboarding

## Target State

```
extensions/clawline/
├── index.ts                    # (unchanged)
├── openclaw.plugin.json        # Add skills array
├── package.json                # (unchanged)
├── AGENTS.md                   # ← MOVE from src/clawline/
├── CLAUDE.md                   # ← MOVE from src/clawline/
├── src/                        # (unchanged)
│   ├── channel.ts
│   ├── outbound.ts
│   └── ...
└── skills/                     # ← NEW directory
    ├── alert-overlay/
    │   └── SKILL.md            # ← MOVE from skills/clawline-alert-overlay/
    ├── device-management/
    │   └── SKILL.md            # ← NEW (consolidates allowlist + pairing + new ops)
    ├── gateway-ops/
    │   └── SKILL.md            # ← MOVE from skills/clawline-gateway-ops/
    ├── media/
    │   └── SKILL.md            # ← MOVE from skills/clawline-media/
    └── webroot/
        └── SKILL.md            # ← NEW (document webRootPath feature)
```

## Migration Steps

### 1. Create skills directory structure
```bash
mkdir -p extensions/clawline/skills/{alert-overlay,device-management,gateway-ops,media,webroot}
```

### 2. Move existing skills (rename without `clawline-` prefix)
```bash
mv skills/clawline-alert-overlay/SKILL.md extensions/clawline/skills/alert-overlay/
mv skills/clawline-gateway-ops/SKILL.md extensions/clawline/skills/gateway-ops/
mv skills/clawline-media/SKILL.md extensions/clawline/skills/media/
# NOTE: allowlist + pairing are consolidated into device-management (new skill)
```

### 3. Remove old skill directories
```bash
rm -r skills/clawline-{alert-overlay,allowlist,gateway-ops,media,pairing}
```

### 4. Move agent guidance files
```bash
mv src/clawline/AGENTS.md extensions/clawline/
mv src/clawline/CLAUDE.md extensions/clawline/
```

### 5. Create device-management skill (consolidates allowlist + pairing)
New file: `extensions/clawline/skills/device-management/SKILL.md`

```markdown
---
name: clawline-device-management
description: Manage Clawline device registrations - list, approve, deny, revoke, and configure admin access.
metadata: { "openclaw": { "skillKey": "clawline-device-management" } }
---

# Clawline Device Management

Manage device registrations for the Clawline provider.

## File Locations

All files under `~/.openclaw/clawline/` (override with `clawline.statePath`):

| File | Purpose |
|------|---------|
| `pending.json` | Devices waiting for approval |
| `allowlist.json` | Approved devices |
| `denylist.json` | Blocked devices (rejected immediately) |

The provider watches these files — edits apply immediately without restart.

## Identity Fields

| Field | Description |
|-------|-------------|
| `deviceId` | Stable per device/app install |
| `claimedName` | Human-friendly label from device (display only) |
| `userId` | Server-assigned routing identity (authoritative) |
| `isAdmin` | Manual flag — controls access to `agent:main:main` |
| `bindingId` | Optional secondary identifier for migrating devices |
| `lastSeenAt` | Timestamp of last connection |

## Operations

### List Pending Devices
```bash
jq '.entries[] | {deviceId, claimedName, deviceInfo}' ~/.openclaw/clawline/pending.json
```

### List Registered Devices
```bash
jq '.entries[] | {deviceId, userId, isAdmin, lastSeenAt}' ~/.openclaw/clawline/allowlist.json
```

### Approve a Device
```bash
python3 - <<'PY'
import json, pathlib, time, uuid, re, unicodedata
root = pathlib.Path.home() / ".openclaw" / "clawline"
pending = json.loads((root / "pending.json").read_text())
allowlist_path = root / "allowlist.json"
allowlist = json.loads(allowlist_path.read_text()) if allowlist_path.exists() else {"version": 1, "entries": []}

device_id = "DEVICE_ID_HERE"  # fill in
entry = next(e for e in pending["entries"] if e["deviceId"] == device_id)

def normalize(claimed):
    if not claimed: return None
    text = unicodedata.normalize("NFKD", claimed)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "_", text).strip("_")
    return text[:64] if text else None

user_id = normalize(entry.get("claimedName")) or f"user_{uuid.uuid4()}"
now = int(time.time() * 1000)

pending["entries"] = [e for e in pending["entries"] if e["deviceId"] != device_id]
allowlist["entries"] = [e for e in allowlist["entries"] if e["deviceId"] != device_id]
allowlist["entries"].append({
    "deviceId": entry["deviceId"],
    "claimedName": entry.get("claimedName"),
    "deviceInfo": entry["deviceInfo"],
    "userId": user_id,
    "bindingId": None,
    "isAdmin": False,
    "tokenDelivered": False,
    "createdAt": now,
    "lastSeenAt": None
})

(root / "pending.json").write_text(json.dumps(pending, indent=2) + "\n")
allowlist_path.write_text(json.dumps(allowlist, indent=2) + "\n")
print("Approved", device_id, "as", user_id)
PY
```

### Deny a Device (block future attempts)
```bash
python3 - <<'PY'
import json, pathlib, time
root = pathlib.Path.home() / ".openclaw" / "clawline"
device_id = "DEVICE_ID_HERE"  # fill in

pending_path = root / "pending.json"
pending = json.loads(pending_path.read_text())
pending["entries"] = [e for e in pending["entries"] if e["deviceId"] != device_id]
pending_path.write_text(json.dumps(pending, indent=2) + "\n")

deny_path = root / "denylist.json"
deny = json.loads(deny_path.read_text()) if deny_path.exists() else []
deny.append({"deviceId": device_id, "createdAt": int(time.time() * 1000)})
deny_path.write_text(json.dumps(deny, indent=2) + "\n")
print("Denied and blocked", device_id)
PY
```

### Revoke a Device (remove from allowlist)
```bash
python3 - <<'PY'
import json, pathlib
root = pathlib.Path.home() / ".openclaw" / "clawline"
device_id = "DEVICE_ID_HERE"  # fill in

allowlist_path = root / "allowlist.json"
allowlist = json.loads(allowlist_path.read_text())
allowlist["entries"] = [e for e in allowlist["entries"] if e["deviceId"] != device_id]
allowlist_path.write_text(json.dumps(allowlist, indent=2) + "\n")
print("Revoked", device_id)
PY
```

### Promote to Admin
```bash
python3 - <<'PY'
import json, pathlib
root = pathlib.Path.home() / ".openclaw" / "clawline"
device_id = "DEVICE_ID_HERE"  # fill in

allowlist_path = root / "allowlist.json"
allowlist = json.loads(allowlist_path.read_text())
for entry in allowlist["entries"]:
    if entry["deviceId"] == device_id:
        entry["isAdmin"] = True
        break
allowlist_path.write_text(json.dumps(allowlist, indent=2) + "\n")
print("Promoted", device_id, "to admin")
PY
```

### Demote from Admin
```bash
python3 - <<'PY'
import json, pathlib
root = pathlib.Path.home() / ".openclaw" / "clawline"
device_id = "DEVICE_ID_HERE"  # fill in

allowlist_path = root / "allowlist.json"
allowlist = json.loads(allowlist_path.read_text())
for entry in allowlist["entries"]:
    if entry["deviceId"] == device_id:
        entry["isAdmin"] = False
        break
allowlist_path.write_text(json.dumps(allowlist, indent=2) + "\n")
print("Demoted", device_id, "from admin")
PY
```

### Clear All Pending
```bash
echo '{"version":1,"entries":[]}' > ~/.openclaw/clawline/pending.json
```

### Re-pair a Device
When a device needs a fresh token:
1. Revoke the device (remove from allowlist)
2. User initiates pairing from the app
3. Approve the new pending request

## Admin Access

- `isAdmin: true` grants access to the main session (`agent:main:main`)
- Admin status is NOT derived automatically — must be set manually
- Multiple devices can be admin
- First approved device does NOT auto-become admin (must be explicit)
```

### 6. Create webroot skill
New file: `extensions/clawline/skills/webroot/SKILL.md`

```markdown
---
name: clawline-webroot
description: Serve static files from the Clawline provider at /www.
metadata: { "openclaw": { "skillKey": "clawline-webroot" } }
---

# Clawline Web Root

The Clawline provider can serve static files from a local directory.

## Configuration

- **Config key:** `channels.clawline.webRootPath`
- **Default:** `~/clawd/www` (or `<workspace>/www`)
- **URL prefix:** `/www` on the Clawline port (default 18800)

## Usage

1. Create the web root directory:
   ```bash
   mkdir -p ~/clawd/www
   ```

2. Add files:
   ```bash
   echo "<h1>Hello</h1>" > ~/clawd/www/index.html
   ```

3. Access via HTTP:
   ```bash
   curl http://localhost:18800/www/index.html
   ```

## Security

- **Dotfiles blocked:** Files starting with `.` return 404
- **Path traversal blocked:** `..` segments return 404
- **Methods:** GET and HEAD only

## Custom Path

Override in config:
```json5
{
  channels: {
    clawline: {
      webRootPath: "/path/to/custom/www"
    }
  }
}
```
```

### 7. Update plugin manifest
Edit `extensions/clawline/openclaw.plugin.json`:

```json
{
  "id": "clawline",
  "channels": ["clawline"],
  "skills": ["./skills"],
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
```

### 8. Update skill metadata
Each moved SKILL.md needs updated metadata. Update skillKey to match new names:

- `clawline-alert-overlay` → `clawline-alert-overlay` (keep prefix for clarity)
- `clawline-gateway-ops` → `clawline-gateway-ops`
- `clawline-media` → `clawline-media`
- NEW: `clawline-device-management` (consolidates allowlist + pairing)
- NEW: `clawline-webroot`

The manifest's `"skills": ["./skills"]` references the directory. The skillKey in each SKILL.md is what appears in `<available_skills>`.

## Post-Migration Verification

1. **Build passes:** `pnpm build`
2. **Skills appear:** With Clawline enabled, skills show in `<available_skills>`
3. **Upstream diff clean:** `git diff upstream/main -- skills/` shows no clawline skills
4. **Extension complete:** All Clawline code + docs + skills in `extensions/clawline/`

## Notes

- The `src/clawline/` directory still contains the **core implementation** (server, config, domain types). That stays where it is — it's the provider runtime.
- Only **agent-facing content** (skills, AGENTS.md, CLAUDE.md) moves into the extension.
- Extension skills are auto-discovered when the plugin is enabled via `resolvePluginSkillDirs()`.
