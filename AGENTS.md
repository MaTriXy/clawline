# Codex / AI Agents - Clawline

Follow the shared instructions in [COMMON.md](./COMMON.md).

## Code Reviews

Use **Claude** for code reviews (cross-validation with Opus):

```bash
$HOME/.claude/local/claude --model claude-opus-4-5-20251101 \
  -p "ultrathink Review the code changes from: $(git diff HEAD~1). Look for bugs, security issues, and adherence to the DI pattern in COMMON.md."
```

Alternative (staged changes):
```bash
$HOME/.claude/local/claude --model claude-opus-4-5-20251101 \
  -p "ultrathink Review the code changes from: $(git diff --staged)."
```

Note: "ultrathink" is appended to the prompt to enable extended thinking mode.

## GitHub Issue Hygiene

When working on GitHub issues, follow these rules:

1. **NEVER close an issue.** Only Flynn closes issues after testing.
2. **Comment when starting.** When you begin work on an issue, comment on it noting that you're starting.
3. **Post progress updates.** Comment on the issue as you work — what you found, what you changed, what you committed.
4. **Comment when done, don't close.** When finished, comment with a final summary (commit hash, what changed, deploy status) but do NOT close the issue.

## Shipping Discipline

- **Main-only shipping.** Only ship/deploy from `origin/main`. Do not deploy from pinned/local-only commits or non-main branches.

## Shipping Policy (Main Only)

- Ship only from `origin/main`. Do not request or expect deploys of pinned commits or branch SHAs.
- When reporting a fix, always state `pushed to origin/main @ <hash>` or `not on main yet`.

## iOS Git Workflow (Flynn Rule)

- Do NOT create git worktrees or new branches for iOS work unless Flynn explicitly instructs you to.
- Work directly on `main` and keep the working tree clean.
