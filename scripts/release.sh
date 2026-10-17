#!/usr/bin/env bash
# Builds, notarizes and staples a release, and with --publish also tags it, creates the GitHub
# release and updates the casks in TheRogue76/homebrew-tap: a pre-release only the
# macos-harness@rc cask, a release both macos-harness and macos-harness@rc.
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
retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    "$@" && return
    [[ $attempt -lt 5 ]] || return 1
    echo "$2 failed; Apple's service may not have answered. Trying again." >&2
    sleep 10
  done
}
retry xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
retry xcrun stapler staple "$APP"
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
write_cask() {
  sed -e "s/@CASK@/$1/" -e "s/@OTHER@/$2/" -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" \
    packaging/macos-harness.rb > "$TAP_DIR/Casks/$1.rb"
  git -C "$TAP_DIR" add "Casks/$1.rb"
}
if [[ ${#PRERELEASE[@]} -gt 0 ]]; then
  write_cask macos-harness@rc macos-harness
  CASK=macos-harness@rc
else
  write_cask macos-harness macos-harness@rc
  write_cask macos-harness@rc macos-harness
  CASK=macos-harness
fi
git -C "$TAP_DIR" commit -q -m "macos-harness $VERSION"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"
echo "Published v$VERSION: brew install --cask therogue76/tap/$CASK"
