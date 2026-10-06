#!/usr/bin/env bash
# Builds, notarizes and staples a release, and with --publish also tags it, creates the GitHub
# release and updates the cask in TheRogue76/homebrew-tap.
#
#   scripts/release.sh                       notarized zip in .build/apps/release
#   scripts/release.sh --publish             also publish
#   scripts/release.sh --publish --prerelease
#
# Needs a notary profile: xcrun notarytool store-credentials macos-harness-notary ...
# (HARNESS_NOTARY_PROFILE picks another).
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=false
PRERELEASE=()
for argument in "$@"; do
  case "$argument" in
    --publish) PUBLISH=true ;;
    --prerelease) PRERELEASE=(--prerelease) ;;
    *) echo "usage: $0 [--publish [--prerelease]]" >&2; exit 2 ;;
  esac
done
PROFILE="${HARNESS_NOTARY_PROFILE:-macos-harness-notary}"
REPO=TheRogue76/macos-harness
TAP=TheRogue76/homebrew-tap
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HarnessProtocol/HarnessVersion.swift)
NOTES=$(awk -v version="## $VERSION" '$0 == version { found = 1; next } found && /^## / { exit } found' CHANGELOG.md)

if $PUBLISH; then
  [[ -n "$NOTES" ]] || { echo "CHANGELOG.md has no \"## $VERSION\" section." >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Release from main." >&2; exit 1; }
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first." >&2; exit 1; }
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "v$VERSION is already tagged." >&2; exit 1; }
fi

scripts/build-app.sh release
APP=".build/apps/release/macOS Harness.app"
ZIP=".build/apps/release/macOS-Harness-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "Notarized $ZIP"
echo "sha256 $SHA256"

$PUBLISH || exit 0

git tag -a "v$VERSION" -m "macOS Harness $VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "macOS Harness $VERSION" --notes "$NOTES" ${PRERELEASE[@]+"${PRERELEASE[@]}"}

TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" packaging/macos-harness.rb > "$TAP_DIR/Casks/macos-harness.rb"
git -C "$TAP_DIR" add Casks/macos-harness.rb
git -C "$TAP_DIR" commit -q -m "macos-harness $VERSION"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"
echo "Published v$VERSION: brew install --cask therogue76/tap/macos-harness"
