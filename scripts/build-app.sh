#!/usr/bin/env bash
# Builds, bundles and signs the helper app (with the CLI inside) and the fixture app.
#
#   scripts/build-app.sh [dev|release] [--install]
#
# dev     debug build, "macOS Harness Dev" and the fixture app, signed with your Apple
#         Development identity
# release universal release build of "macOS Harness" only, signed with your Developer ID
#         (hardened runtime, secure timestamp), ready for scripts/release.sh to notarize
#
# --install (dev only) stops the running helper, copies both apps to ~/Applications and
# links the CLI as ~/.local/bin/macos-harness-dev.
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
    ARCHS=()
    TIMESTAMP=--timestamp=none
    BUNDLE_ID="$BASE_ID.dev"
    APP_NAME="macOS Harness Dev"
    IDENTITY_KIND="Apple Development"
    ;;
  release)
    CONFIG=release
    ARCHS=(--arch arm64 --arch x86_64)
    TIMESTAMP=--timestamp
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
IDENTITY="${HARNESS_SIGN_IDENTITY:-$(python3 scripts/pick-identity.py "$IDENTITY_KIND")}"
if [[ -z "$IDENTITY" ]]; then
  echo "No \"$IDENTITY_KIND\" signing identity found; set HARNESS_SIGN_IDENTITY." >&2
  exit 1
fi

swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)
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
  codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@"
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
cp Resources/AppIcon.icns "$HELPER_APP/Contents/Resources/AppIcon.icns"
mkdir -p "$HELPER_APP/Contents/Resources/skills"
cp -R skills/macos-harness "$HELPER_APP/Contents/Resources/skills/"
plutil -insert CFBundleIconFile -string AppIcon "$HELPER_APP/Contents/Info.plist"
sign --identifier "$BUNDLE_ID.cli" "$HELPER_APP/Contents/MacOS/macos-harness"
sign "$HELPER_APP"

if [[ "$VARIANT" == dev ]]; then
  FIXTURE_APP="$OUT/Harness Fixture.app"
  bundle "$FIXTURE_APP" "$BASE_ID.fixture" "Harness Fixture" harness-fixture false
  sign "$FIXTURE_APP"
  codesign --verify --strict "$FIXTURE_APP"
fi

codesign --verify --strict "$HELPER_APP"
echo "Built $HELPER_APP ($VERSION, signed with $IDENTITY_KIND)"

if [[ "$INSTALL" == "--install" ]]; then
  if [[ "$VARIANT" != dev ]]; then
    echo "--install is for dev builds; release installs come from Homebrew." >&2
    exit 2
  fi
  DEST="$HOME/Applications"
  mkdir -p "$DEST" "$HOME/.local/bin"
  pkill -f "$DEST/$APP_NAME.app/Contents/MacOS/macos-harness-helper" || true
  pkill -f "$DEST/Harness Fixture.app/Contents/MacOS/harness-fixture" || true
  sleep 0.5
  rm -rf "$DEST/$APP_NAME.app" "$DEST/Harness Fixture.app"
  ditto "$HELPER_APP" "$DEST/$APP_NAME.app"
  ditto "$FIXTURE_APP" "$DEST/Harness Fixture.app"
  OLD_LINK="$HOME/.local/bin/macos-harness"
  if [[ -L "$OLD_LINK" && "$(readlink "$OLD_LINK")" == "$DEST/$APP_NAME.app/"* ]]; then rm "$OLD_LINK"; fi
  ln -sf "$DEST/$APP_NAME.app/Contents/MacOS/macos-harness" "$HOME/.local/bin/macos-harness-dev"
  echo "Installed to $DEST; CLI linked at ~/.local/bin/macos-harness-dev"
fi
