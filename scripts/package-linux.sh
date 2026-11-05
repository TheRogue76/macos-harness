#!/usr/bin/env bash
# Builds the Linux release for this machine's architecture and packs it: a tarball with
# install.sh, and with --packages also a .deb and an .rpm through nfpm (which must be on PATH).
# Everything lands in .build/packages.
#
#   scripts/package-linux.sh [--packages]
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGES=false
for argument in "$@"; do
  case "$argument" in
    --packages) PACKAGES=true ;;
    *) echo "usage: $0 [--packages]" >&2; exit 2 ;;
  esac
done

VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HarnessProtocol/HarnessVersion.swift)
ARCH=$(uname -m)
NAME=otto-harness
UUID=otto@therogue76.github.io
APP_ID=io.github.therogue76.Otto
OUT=.build/packages
STAGE="$OUT/stage-$ARCH"

swift build -c release --static-swift-stdlib
BIN=$(swift build -c release --static-swift-stdlib --show-bin-path)
[[ -x "$BIN/otto-tower" ]] || { echo "otto-tower wasn't built: install GTK 4 and libadwaita's development files." >&2; exit 1; }

rm -rf "$STAGE"
LIBEXEC="$STAGE/usr/libexec/$NAME"
SHARE="$STAGE/usr/share"
mkdir -p "$STAGE/usr/bin" "$LIBEXEC" "$STAGE/usr/lib/systemd/user" "$SHARE/applications" "$SHARE/gnome-shell/extensions" \
  "$SHARE/icons/hicolor/scalable/apps" "$SHARE/icons/hicolor/symbolic/apps" "$SHARE/$NAME/skills" "$SHARE/doc/$NAME"
install -m 755 "$BIN/otto" "$STAGE/usr/bin/otto"
install -m 755 "$BIN/otto-helper" "$BIN/otto-tower" "$LIBEXEC/"
strip "$STAGE/usr/bin/otto" "$LIBEXEC/otto-helper" "$LIBEXEC/otto-tower"
install -m 644 packaging/linux/otto.socket packaging/linux/otto.service "$STAGE/usr/lib/systemd/user/"
sed "s|@HELPER@|/usr/libexec/$NAME/otto-helper|" "packaging/linux/$APP_ID.desktop" > "$SHARE/applications/$APP_ID.desktop"
cp -R "packaging/linux/gnome-extension/$UUID" "$SHARE/gnome-shell/extensions/"
install -m 644 Resources/branding/otto/otto-icon.svg "$SHARE/icons/hicolor/scalable/apps/$APP_ID.svg"
install -m 644 Resources/branding/otto/otto-symbolic.svg "$SHARE/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg"
cp -R skills/otto "$SHARE/$NAME/skills/"
install -m 644 LICENSE "$SHARE/doc/$NAME/"

TARBALL="$OUT/$NAME-$VERSION-linux-$ARCH.tar.gz"
TOP="$NAME-$VERSION-linux-$ARCH"
rm -rf "${OUT:?}/$TOP"
mkdir -p "$OUT/$TOP"
cp -R "$STAGE/usr/." "$OUT/$TOP/"
install -m 755 packaging/linux/install.sh "$OUT/$TOP/install.sh"
tar -C "$OUT" -czf "$TARBALL" "$TOP"
rm -rf "${OUT:?}/$TOP"
echo "$TARBALL"

if $PACKAGES; then
  case "$ARCH" in
    x86_64) NFPM_ARCH=amd64 ;;
    aarch64) NFPM_ARCH=arm64 ;;
    *) echo "No package architecture for $ARCH." >&2; exit 1 ;;
  esac
  sed -e "s|@ROOT@|$PWD|" -e "s|@ARCH@|$NFPM_ARCH|" -e "s|@VERSION@|$VERSION|" -e "s|@STAGE@|$PWD/$STAGE|" packaging/linux/nfpm.yaml > "$OUT/nfpm.yaml"
  for packager in deb rpm; do
    nfpm package -f "$OUT/nfpm.yaml" -p "$packager" -t "$OUT/"
  done
  ls "$OUT"/*.deb "$OUT"/*.rpm
fi
