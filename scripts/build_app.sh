#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="WorktreeCleaner"
DISPLAY_NAME="Worktree Cleaner"
DIST_DIR="$PKG_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
BUILD_DMG=false
BUILD_ZIP=false
UNIVERSAL=false
VERSION="${VERSION:-1.0.0}"

for arg in "$@"; do
  case "$arg" in
    --dmg) BUILD_DMG=true ;;
    --zip) BUILD_ZIP=true ;;
    --universal) UNIVERSAL=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

echo "🔨 Building $APP_NAME ($VERSION, release)..."
cd "$PKG_DIR"

if [[ "$UNIVERSAL" == true ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_PATH="$PKG_DIR/.build/apple/Products/Release/$APP_NAME"
else
  swift build -c release
  BIN_PATH="$PKG_DIR/.build/release/$APP_NAME"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "❌ Binary not found at $BIN_PATH"
  exit 1
fi

echo "🎨 Generating AppIcon.icns..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_PNG="$TMP_DIR/icon_1024.png"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

swift "$SCRIPT_DIR/generate_icon.swift" "$BASE_PNG"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

echo "📦 Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh_CN</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>WorktreeCleaner</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.isdou.worktree-cleaner</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Worktree Cleaner scans Git repositories on your Desktop to detect and clean up stale worktrees.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Worktree Cleaner scans Git repositories in Downloads to detect and clean up stale worktrees.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Worktree Cleaner scans Git repositories in Documents to detect and clean up stale worktrees.</string>
</dict>
</plist>
PLIST

# 自动探测本机签名证书：优先 CODESIGN_IDENTITY -> Developer ID Application -> Apple Development -> ad-hoc ("-")
resolve_signing_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "$CODESIGN_IDENTITY"
    return
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  local dev_id
  dev_id="$(printf '%s\n' "$identities" | grep -m1 '"Developer ID Application:' | awk '{print $2}' || true)"
  if [[ -n "$dev_id" ]]; then
    echo "$dev_id"
    return
  fi

  local apple_dev
  apple_dev="$(printf '%s\n' "$identities" | grep -m1 '"Apple Development:' | awk '{print $2}' || true)"
  if [[ -n "$apple_dev" ]]; then
    echo "$apple_dev"
    return
  fi

  echo "-"
}

SIGN_IDENTITY="$(resolve_signing_identity)"
echo "🔏 Signing with identity: $SIGN_IDENTITY"

sign_with_identity() {
  local id="$1"
  if [[ "$id" == "-" ]]; then
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
  else
    codesign --force --deep --options runtime --timestamp --sign "$id" "$APP_BUNDLE" >/dev/null 2>&1
  fi
}

if ! sign_with_identity "$SIGN_IDENTITY"; then
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "⚠️ Signing with $SIGN_IDENTITY failed (e.g., locked keychain), falling back..."
    FALLBACK_APPLE_DEV="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development:' | awk '{print $2}' || true)"
    if [[ -n "$FALLBACK_APPLE_DEV" && "$FALLBACK_APPLE_DEV" != "$SIGN_IDENTITY" ]] && sign_with_identity "$FALLBACK_APPLE_DEV"; then
      echo "✅ Signed with fallback Apple Development identity: $FALLBACK_APPLE_DEV"
    else
      sign_with_identity "-" || true
      echo "✅ Signed with ad-hoc identity (-)"
    fi
  fi
fi

echo "✅ Built app: $APP_BUNDLE"

if [[ "$BUILD_ZIP" == true ]]; then
  ZIP_PATH="$DIST_DIR/${APP_NAME}-macOS.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  echo "✅ Built zip: $ZIP_PATH"
fi

if [[ "$BUILD_DMG" == true ]]; then
  DMG_STAGE="$TMP_DIR/dmg-stage"
  DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
  mkdir -p "$DMG_STAGE"
  cp -R "$APP_BUNDLE" "$DMG_STAGE/"
  ln -s /Applications "$DMG_STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "✅ Built dmg: $DMG_PATH"
fi
