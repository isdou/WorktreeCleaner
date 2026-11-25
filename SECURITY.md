# Security Policy

Worktree Cleaner interacts directly with your local Git repositories, uncommitted files, and macOS filesystem. Safety is a primary design constraint.

## Built-in Safety Architecture

- **Trash-First Removal**: Deletions use `FileManager.default.trashItem` by default so removed directories remain recoverable in macOS Trash.
- **Active Process Guard (`lsof`)**: Worktrees with live processes whose `cwd` resides inside the directory are flagged and blocked from standard removal.
- **Protected Branches**: `main`, `master`, `develop`, `dev`, `prd`, `production`, and `staging` are never deleted even when "Also delete local branch" is checked.
- **MCP Tool Visibility Isolation**: In the Antigravity MCP App plugin, all destructive/mutation tools (`remove_worktree`, `prune_missing_worktrees`, `slim_worktree_caches`, `push_worktree`, `copy_precious_files`, `open_in_finder`) declare `_meta.ui.visibility: ["app"]` and cannot be invoked by the language model without direct user UI confirmation.

## Reporting a Vulnerability or Data-Loss Risk

If you discover a scenario that could lead to unintended data loss, privilege escalation, or unintended tool execution:

- **Please do NOT post sensitive details publicly first.**
- Use GitHub's **Private Vulnerability Reporting** under the **Security** tab (`https://github.com/isdou/WorktreeCleaner/security/advisories/new`), or contact the maintainer via GitHub profile if unavailable.
- Include macOS version, reproduction steps, and affected commit or release tag.
