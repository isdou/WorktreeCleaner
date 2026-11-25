---
name: worktree-cleaner
description: Visually inspect, push, slim build caches, or safely remove Git worktrees created by Codex, Claude Code, Cursor, or Trae inside Antigravity using the Worktree Cleaner MCP App.
---

# Worktree Cleaner

Use the `worktree-cleaner_worktree-cleaner` MCP server whenever the user asks to inspect, clean up, slim caches, push, or audit Git worktrees on macOS.

## Default Workflow

1. **Prefer the interactive workbench**: Call `open_worktree_cleaner` (all parameters optional; pass `filter` or `search` if the user narrowed the scope) so the user can visually inspect safety levels, Codex/Claude task context, uncommitted diffs, and confirm deletions directly inside Antigravity.
2. **Headless automation**: When the user asks for a quick report or targeted action without opening the workbench, call `scan_worktrees`, `get_worktree_diff`, `slim_worktree_caches`, `copy_precious_files`, `push_worktree`, `remove_worktree`, or `prune_missing_worktrees`.
3. **Safety first**: Never pass `force: true` to `remove_worktree` unless the user explicitly confirms stopping or overriding active processes. Always keep `moveToTrash: true` and `backupCommitFirst: true` by default.
