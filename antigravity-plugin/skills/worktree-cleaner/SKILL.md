---
name: worktree-cleaner
description: Visually inspect, push, slim build caches, or safely remove Git worktrees created by Codex, Claude Code, Cursor, or Trae inside Antigravity using the Worktree Cleaner MCP App.
---

# Worktree Cleaner

Use the `worktree-cleaner_worktree-cleaner` MCP server whenever the user asks to inspect, clean up, slim caches, push, or audit Git worktrees on macOS.

## Surface Selection

1. **Quick in-chat check (Inline Card)**: Call `show_worktrees_inline` when the user asks a conversational question like "看看哪些 worktree 可以删" or "检查当前仓库的 worktree". It renders a compact interactive card directly inside the chat stream with checkboxes, disk totals, and one-click Trash cleanup or context attachment.
2. **Full Workbench (Side Pane / Global Page)**: Call `open_worktree_cleaner` when the user wants to browse all repositories in detail, compare diffs, push branches, or keep a persistent side-pane inspector open while coding.
3. **Read-Only Analysis**: Use `scan_worktrees` and `get_worktree_diff` when you need structured diagnostics or raw diffs to review uncommitted changes before advising the user.

## Safety Isolation Model

All destructive and mutation tools (`remove_worktree`, `prune_missing_worktrees`, `slim_worktree_caches`, `push_worktree`, `copy_precious_files`, `open_in_finder`) are intentionally restricted to `_meta.ui.visibility: ["app"]` so the model can never accidentally delete or modify worktrees. Always present findings clearly and let the user confirm any cleanup, cache slimming, or push action directly inside the Worktree Cleaner card or workbench.
