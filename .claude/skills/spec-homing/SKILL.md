---
name: spec-homing
description: Find and place technical specs. Use when writing a new spec, looking for an existing spec, or referencing spec conventions.
---

# Spec Homing

Where specs live, how to find them, how to name them.

## Canonical Location

All specs live on the NFS shared workspace, visible from both TARS and eezo:

```
/Users/mike/shared-workspace/{project}/specs/{specname}.md
```

**Projects:**
- `clawline` — Clawline iOS client + provider
- `helm` — Helm app
- `floatty` — Floatty app
- `shared` — Cross-project or infrastructure specs

**Do NOT put specs in:**
- `scratch/` (ephemeral, not preserved)
- Git repo `docs/` directly (synced FROM shared workspace, not the other way)
- Agent workspace files

## Finding a Spec

To find a spec by topic:
```bash
ls /Users/mike/shared-workspace/*/specs/
grep -rl "search term" /Users/mike/shared-workspace/*/specs/
```

Archived/superseded specs go in `specs/archive/` within each project.

## Naming

- Lowercase, hyphenated: `terminal-bubbles.md`, `bubble-sizing-v2.md`
- Name describes the feature or system, not the ticket number
- Version suffix (`-v2`) only when superseding a prior spec

## Writing a New Spec

1. Create the file at the canonical path
2. No mandatory template — structure should fit the problem
3. Include at minimum: Goal, Non-Goals, Architecture/Design, Open Questions

## Syncing to Repos

Specs sync from the shared workspace into git repos via cron jobs (e.g., `sync-clawline-docs`). The shared workspace is the source of truth — edit there, not in the repo.
