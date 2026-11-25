# Contributing to Worktree Cleaner

Thank you for helping make **Worktree Cleaner** safer, faster, and more pleasant for everyone.

## Repository Structure

```text
├── Sources/
│   ├── WorktreeCleanerCore/   # Shared scanning, safety heuristics, lsof, git cherry, MCP protocol
│   ├── WorktreeCleaner/       # Native macOS SwiftUI + Liquid Glass app & menu bar extra
│   └── WorktreeCleanerMCP/    # Native stdio MCP App (SEP-1865) server entry point
├── mcp-app/                   # Single-file HTML UI (@modelcontextprotocol/ext-apps + esbuild)
├── antigravity-plugin/        # Antigravity plugin manifest, MCP config, and SKILL.md
├── Tests/WorktreeCleanerTests/# Swift Testing suite
└── scripts/                   # .app/.dmg bundler, AppIcon generator, Antigravity plugin installer
```

## Development Setup

### Prerequisites
- macOS 14+ (macOS 26+ recommended to test Tahoe Liquid Glass surfaces)
- Xcode 16+ / Swift 6.0+
- Node.js 18+ (only if modifying `mcp-app/`)

### Running Tests & Building

```bash
# Run core & MCP protocol tests
swift test

# Build & run the macOS app bundle
./scripts/build_app.sh --dmg
open dist/WorktreeCleaner.app

# Rebuild & install the Antigravity MCP App plugin locally
./scripts/install_antigravity_plugin.sh
```

## Coding Guidelines

1. **Shared Logic Lives in `WorktreeCleanerCore`**: Never duplicate Git, `lsof`, session-reading, or removal logic between the SwiftUI app and `WorktreeCleanerMCP`.
2. **Safety First**: Any new cleanup capability must preserve **Trash-first** behavior, respect active-process locks, and never expose destructive MCP tools to the LLM directly (`_meta.ui.visibility: ["app"]`).
3. **No Personal Paths or Machine Secrets**: Never commit personal directories, certificate hashes, or API keys in source, tests, or scripts.
4. **Native macOS Restraint**: Follow macOS HIG & Liquid Glass principles — minimal secondary clutter, neutral surfaces, and single clear primary actions.

## Submitting a Pull Request

1. Fork the repository and create a topic branch from `main`.
2. Add or update unit tests in `Tests/WorktreeCleanerTests/`.
3. Verify `swift test` passes cleanly.
4. Open a Pull Request describing the motivation, behavior change, and test results.
