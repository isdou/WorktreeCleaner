<div align="center">

# Worktree Cleaner

**A native macOS Liquid Glass inspector & safe cleaner for Git worktrees left behind by AI coding agents.**

*See what each worktree actually did, commit & push unfinished changes in one click, slim down `node_modules`, and move stale directories to Trash — without risking lost work.*

[简体中文](README_ZH.md) · [Releases](https://github.com/isdou/WorktreeCleaner/releases)

</div>

---

## Why Worktree Cleaner?

AI coding agents (**Codex**, **Claude Code**, **Cursor**, **Trae**) love spinning up isolated Git worktrees under hidden directories like `~/.codex/worktrees` or `.claude/worktrees`. After a few days of parallel coding:

- Dozens of mystery branches pile up and silently eat **10–50+ GB** of SSD space.
- You are afraid to delete them via CLI because you forgot **what that worktree actually built**, whether it has **uncommitted `.env` / code changes**, or if a background agent is **still running inside it**.

**Worktree Cleaner** solves this with a calm, native macOS UI (built with SwiftUI & Tahoe Liquid Glass).

---

## Key Features

- **Automatic Discovery & Orphan Reconciliation**
  - Scans common developer roots (`~/Projects`, `~/Developer`, `~/Code`, `~/Workspace`, `~/src`, `~/Desktop`, `~/Downloads`, up to 2 levels deep) plus `~/.codex/worktrees`, `~/.claude/worktrees`, `~/.cursor/worktrees`, `~/.trae-cn/worktrees`, and `<repo>/.claude/worktrees`.
  - Finds **broken git worktrees** (main repo deleted) and **`.git`-less leftover directories** that `git worktree list` cannot see.
- **"What Changed" Context Recall**
  - Reads **Codex** (`~/.codex/state_5.sqlite`, read-only) and **Claude Code** (`~/.claude/projects/*.jsonl`) session titles/prompts so you immediately remember why the worktree exists.
  - Compares against your default branch: commit count, touched modules, line stats, **Squash/Rebase merge detection** (`git cherry`), and optional **GitHub PR status** via `gh`.
- **4-Layer Safety Guardrails**
  - **Active Process Lock**: Detects live processes whose `cwd` is inside the worktree via `lsof` and blocks accidental deletion.
  - **Freshness Guard**: Configurable cooldown window (default 24h) automatically skips recently active worktrees during bulk selection.
  - **Precious Ignored Files Alert**: Catches `.env.local`, `secrets.json`, `.pem`, `.sqlite` hidden by `.gitignore` — with one-click **Copy to Main Repo**.
  - **Trash-First Undo**: Moves removed directories to macOS Trash and prunes Git metadata (`git worktree prune`), instead of irreversible `rm -rf`.
- **Flexible Workflows**
  - **Slim Build Caches Only**: Trash `node_modules`, `.next`, `.build`, `target`, `DerivedData`, `.venv` while keeping 100% of your source code and uncommitted edits.
  - **One-Click Commit & Push**: Stage, commit (with prefilled task message), push (even from Detached HEAD), and optionally remove right after push.
  - **Optional Branch Cleanup**: Clean up matching synced local branches while protecting `main`/`master`/`develop`/`prd`.
- **Native macOS Experience**
  - Menu bar extra with live space overview + full split-view inspector (`⌘K` search, `⌘R` rescan, `↑`/`↓` navigation, context menus, IDE launcher for Cursor / VS Code / Zed / Xcode, Bilingual EN/ZH, Launch at Login).

---

## Installation

### Download Release (macOS 14+, Liquid Glass on macOS 26+)

1. Download `WorktreeCleaner.dmg` from [GitHub Releases](https://github.com/isdou/WorktreeCleaner/releases).
2. Drag **Worktree Cleaner** into `/Applications`.
3. If macOS Gatekeeper warns about an unsigned/ad-hoc build on first launch, run:
   ```bash
   xattr -cr "/Applications/Worktree Cleaner.app"
   ```

### Build from Source

Requires Xcode 16+ / Swift 6.0+ on macOS:

```bash
git clone https://github.com/isdou/WorktreeCleaner.git
cd WorktreeCleaner
swift test
./scripts/build_app.sh --dmg
open dist/WorktreeCleaner.app
```

---

## License

[MIT License](LICENSE)
