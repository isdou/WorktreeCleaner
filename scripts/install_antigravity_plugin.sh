#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="${ANTIGRAVITY_PLUGIN_DIR:-$HOME/.gemini/config/plugins/worktree-cleaner}"

echo "🎨 Building single-file MCP App frontend..."
cd "$REPO_DIR/mcp-app"
if [[ ! -d node_modules ]]; then
  npm install --no-audit --no-fund
fi
npm run build

echo "🔨 Building WorktreeCleanerMCP (release)..."
cd "$REPO_DIR"
swift build -c release --product WorktreeCleanerMCP
MCP_BIN="$REPO_DIR/.build/release/WorktreeCleanerMCP"
if [[ ! -f "$MCP_BIN" ]]; then
  echo "❌ WorktreeCleanerMCP binary not found at $MCP_BIN" >&2
  exit 1
fi

echo "📦 Installing Antigravity plugin to $PLUGIN_DIR..."
mkdir -p "$PLUGIN_DIR/bin" "$PLUGIN_DIR/dist" "$PLUGIN_DIR/assets" "$PLUGIN_DIR/skills/worktree-cleaner"

cp "$REPO_DIR/antigravity-plugin/plugin.json" "$PLUGIN_DIR/plugin.json"
cp "$REPO_DIR/antigravity-plugin/mcp_config.json" "$PLUGIN_DIR/mcp_config.json"
cp "$REPO_DIR/antigravity-plugin/assets/logo.svg" "$PLUGIN_DIR/assets/logo.svg"
cp "$REPO_DIR/antigravity-plugin/skills/worktree-cleaner/SKILL.md" "$PLUGIN_DIR/skills/worktree-cleaner/SKILL.md"
cp "$MCP_BIN" "$PLUGIN_DIR/bin/WorktreeCleanerMCP"
chmod +x "$PLUGIN_DIR/bin/WorktreeCleanerMCP"
cp "$REPO_DIR/mcp-app/dist/worktree-cleaner-app.html" "$PLUGIN_DIR/dist/worktree-cleaner-app.html"

# 尝试使用本机开发者证书签名，若无则回退 ad-hoc
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application:' | awk '{print $2}' || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development:' | awk '{print $2}' || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$PLUGIN_DIR/bin/WorktreeCleanerMCP" >/dev/null 2>&1 || true
else
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$PLUGIN_DIR/bin/WorktreeCleanerMCP" >/dev/null 2>&1 \
    || codesign --force --sign - "$PLUGIN_DIR/bin/WorktreeCleanerMCP" >/dev/null 2>&1 \
    || true
fi

# 若处于 Antigravity 环境且提供 CSRF token，顺手通知刷新 MCP Server
if [[ -n "${ANTIGRAVITY_CSRF_TOKEN:-}" ]]; then
  curl -sf -H "Content-Type: application/json" \
    -H "x-codeium-csrf-token: ${ANTIGRAVITY_CSRF_TOKEN}" \
    -d '{"serverName": "worktree-cleaner_worktree-cleaner"}' \
    "http://${ANTIGRAVITY_LS_ADDRESS:-localhost:5387}/exa.language_server_pb.LanguageServerService/RefreshMcpServers" >/dev/null 2>&1 || true
fi

echo "✅ Installed Antigravity MCP App plugin: $PLUGIN_DIR"
