#!/usr/bin/env bash
# Builds, notarizes and staples a release, and with --publish also tags it, creates the GitHub
# release and updates TheRogue76/homebrew-tap: a pre-release only the otto-harness@rc cask and
# formula, a release both casks and both formulas.
# Each moves people from the casks before 2.0 (macos-harness, macos-harness@rc) with
# cask_renames.json. The formulas wait for the Linux packages workflow, which publishing starts.
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
REPO=TheRogue76/otto-harness
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
APP=".build/apps/release/Otto.app"
ZIP=".build/apps/release/Otto-$VERSION.zip"

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

git tag -a "v$VERSION" -m "Otto $VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Otto $VERSION" --notes "$NOTES" ${PRERELEASE[@]+"${PRERELEASE[@]}"}

TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks" "$TAP_DIR/Formula"
write_cask() {
  sed -e "s/@CASK@/$1/" -e "s/@OTHER@/$2/" -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA256/" \
    packaging/otto-harness.rb > "$TAP_DIR/Casks/$1.rb"
  git -C "$TAP_DIR" add "Casks/$1.rb"
}
retire_cask() {
  if [[ -f "$TAP_DIR/Casks/$1.rb" ]]; then git -C "$TAP_DIR" rm -q "Casks/$1.rb"; fi
  python3 - "$TAP_DIR/cask_renames.json" "$1" "$2" <<'PY'
import json, os, sys
path, old, new = sys.argv[1:]
renames = json.load(open(path)) if os.path.exists(path) else {}
renames[old] = new
with open(path, "w") as file:
    json.dump(renames, file, indent=2, sort_keys=True)
    file.write("\n")
PY
  git -C "$TAP_DIR" add cask_renames.json
}
write_formula() {
  local run="" assets
  for _ in $(seq 1 30); do
    run=$(gh run list --repo "$REPO" --workflow linux-packages.yml --event release --limit 5 --json databaseId,headBranch \
      -q ".[] | select(.headBranch == \"v$VERSION\") | .databaseId" | head -1)
    [[ -n "$run" ]] && break
    sleep 10
  done
  [[ -n "$run" ]] || { echo "The Linux packages workflow didn't start for v$VERSION." >&2; return 1; }
  gh run watch "$run" --repo "$REPO" --exit-status > /dev/null || { echo "The Linux packages workflow failed." >&2; return 1; }
  assets=$(mktemp -d)
  gh release download "v$VERSION" --repo "$REPO" --pattern "*.tar.gz" --dir "$assets" || return 1
  for arch in x86_64 aarch64; do
    [[ -f "$assets/otto-harness-$VERSION-linux-$arch.tar.gz" ]] || { echo "The release has no $arch tarball." >&2; return 1; }
  done
  sed -e "s/@CLASS@/$2/" -e "s/@VERSION@/$VERSION/" \
    -e "s/@SHA256_X86_64@/$(shasum -a 256 "$assets/otto-harness-$VERSION-linux-x86_64.tar.gz" | awk '{print $1}')/" \
    -e "s/@SHA256_AARCH64@/$(shasum -a 256 "$assets/otto-harness-$VERSION-linux-aarch64.tar.gz" | awk '{print $1}')/" \
    packaging/otto-harness-formula.rb > "$TAP_DIR/Formula/$1.rb"
  git -C "$TAP_DIR" add "Formula/$1.rb"
  rm -rf "$assets"
}
if [[ ${#PRERELEASE[@]} -gt 0 ]]; then
  write_cask otto-harness@rc otto-harness
  retire_cask macos-harness@rc otto-harness@rc
  write_formula otto-harness@rc OttoHarnessATRc || echo "The otto-harness@rc formula wasn't updated; the casks still are." >&2
  CASK=otto-harness@rc
else
  write_cask otto-harness otto-harness@rc
  write_cask otto-harness@rc otto-harness
  retire_cask macos-harness otto-harness
  retire_cask macos-harness@rc otto-harness@rc
  if write_formula otto-harness OttoHarness; then
    sed "s/^class OttoHarness < Formula/class OttoHarnessATRc < Formula/" "$TAP_DIR/Formula/otto-harness.rb" > "$TAP_DIR/Formula/otto-harness@rc.rb"
    git -C "$TAP_DIR" add "Formula/otto-harness@rc.rb"
  else
    echo "The otto-harness formulas weren't updated; the casks still are." >&2
  fi
  CASK=otto-harness
fi
git -C "$TAP_DIR" commit -q -m "otto-harness $VERSION"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR"
echo "Published v$VERSION: brew install --cask therogue76/tap/$CASK on the Mac, brew install therogue76/tap/$CASK on Linux"
