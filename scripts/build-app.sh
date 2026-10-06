#!/usr/bin/env bash
# Builds, bundles and signs the helper app (with the CLI inside) and the fixture app.
#
#   scripts/build-app.sh [dev|release] [--install]
#
# dev     debug build, "macOS Harness Dev", signed with your Apple Development identity
# release release build, "macOS Harness", signed with your Developer ID (notarization comes in M4)
#
# --install (dev only) stops the running helper, copies both apps to ~/Applications and
# links the CLI into ~/.local/bin. macOS permissions survive reinstalls because they are
# tied to the bundle ID and signing identity, not to the file.
#
# HARNESS_SIGN_IDENTITY overrides the signing identity (a name or SHA-1 hash).
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-dev}"
INSTALL="${2:-}"
BASE_ID="io.github.therogue76.macos-harness"

case "$VARIANT" in
  dev)
    CONFIG=debug
    BUNDLE_ID="$BASE_ID.dev"
    APP_NAME="macOS Harness Dev"
    IDENTITY_KIND="Apple Development"
    ;;
  release)
    CONFIG=release
    BUNDLE_ID="$BASE_ID"
    APP_NAME="macOS Harness"
    IDENTITY_KIND="Developer ID Application"
    ;;
  *)
    echo "usage: $0 [dev|release] [--install]" >&2
    exit 2
    ;;
esac

VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HarnessProtocol/HarnessVersion.swift)
IDENTITY="${HARNESS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "$IDENTITY_KIND" | head -1 | awk '{print $2}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "No \"$IDENTITY_KIND\" signing identity found; set HARNESS_SIGN_IDENTITY." >&2
  exit 1
fi

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
OUT=".build/apps/$VARIANT"
mkdir -p "$OUT"

# write_plist <path> <bundle id> <name> <executable> <is agent: true|false>
write_plist() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundleDisplayName</key><string>$3</string>
  <key>CFBundleExecutable</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><$5/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
}

sign() {
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"
}

# bundle <app path> <bundle id> <name> <main executable> <is agent>
bundle() {
  local app="$1"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$4" "$app/Contents/MacOS/"
  write_plist "$app/Contents/Info.plist" "$2" "$3" "$4" "$5"
}

HELPER_APP="$OUT/$APP_NAME.app"
bundle "$HELPER_APP" "$BUNDLE_ID" "$APP_NAME" macos-harness-helper true
cp "$BIN/macos-harness" "$HELPER_APP/Contents/MacOS/"
sign --identifier "$BUNDLE_ID.cli" "$HELPER_APP/Contents/MacOS/macos-harness"
sign "$HELPER_APP"

FIXTURE_APP="$OUT/Harness Fixture.app"
bundle "$FIXTURE_APP" "$BASE_ID.fixture" "Harness Fixture" harness-fixture false
sign "$FIXTURE_APP"

codesign --verify --strict "$HELPER_APP" "$FIXTURE_APP"
echo "Built $HELPER_APP and $FIXTURE_APP ($VERSION, signed with $IDENTITY_KIND)"

if [[ "$INSTALL" == "--install" ]]; then
  if [[ "$VARIANT" != dev ]]; then
    echo "--install is for dev builds; release installs come from Homebrew." >&2
    exit 2
  fi
  DEST="$HOME/Applications"
  mkdir -p "$DEST" "$HOME/.local/bin"
  # Stop the old helper so its socket and binary are released.
  pkill -f "$DEST/$APP_NAME.app/Contents/MacOS/macos-harness-helper" || true
  pkill -f "$DEST/Harness Fixture.app/Contents/MacOS/harness-fixture" || true
  sleep 0.5
  # Replace whole bundles rather than overwriting signed binaries in place.
  rm -rf "$DEST/$APP_NAME.app" "$DEST/Harness Fixture.app"
  ditto "$HELPER_APP" "$DEST/$APP_NAME.app"
  ditto "$FIXTURE_APP" "$DEST/Harness Fixture.app"
  ln -sf "$DEST/$APP_NAME.app/Contents/MacOS/macos-harness" "$HOME/.local/bin/macos-harness"
  echo "Installed to $DEST; CLI linked at ~/.local/bin/macos-harness"
fi
