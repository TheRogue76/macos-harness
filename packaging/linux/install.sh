#!/usr/bin/env bash
# Installs Otto from this unpacked tarball into ~/.local, or with --prefix into another folder
# such as /usr/local (with sudo). --uninstall removes what it installed.
#
#   ./install.sh [--prefix DIR] [--uninstall]
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="$HOME/.local"
UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a folder}"; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) echo "usage: $0 [--prefix DIR] [--uninstall]" >&2; exit 2 ;;
  esac
done
PREFIX="${PREFIX%/}"

NAME=otto-harness
UUID=otto@therogue76.github.io
APP_ID=io.github.therogue76.Otto
HELPER="$PREFIX/libexec/$NAME/otto-helper"
UNITS="$PREFIX/share/systemd/user"
[[ "$PREFIX" == "$HOME"/* ]] && SCOPE=--user || SCOPE=--global

FILES=(
  "bin/otto" "bin/macos-harness" "libexec/$NAME" "share/applications/$APP_ID.desktop"
  "share/gnome-shell/extensions/$UUID" "share/icons/hicolor/scalable/apps/$APP_ID.svg"
  "share/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg" "share/$NAME" "share/doc/$NAME"
  "share/systemd/user/otto.socket" "share/systemd/user/otto.service"
)

if $UNINSTALL; then
  if [[ "$SCOPE" == --user ]]; then systemctl --user disable --now otto.socket otto.service >/dev/null 2>&1 || true
  else systemctl --global disable otto.socket >/dev/null 2>&1 || true; fi
  for file in "${FILES[@]}"; do rm -rf "${PREFIX:?}/$file"; done
  echo "Removed Otto from $PREFIX. Your policy, journal and logs stay in ~/.config/otto and ~/.local/state/otto."
  exit 0
fi

mkdir -p "$PREFIX/bin" "$PREFIX/libexec/$NAME" "$PREFIX/share/applications" "$PREFIX/share/gnome-shell/extensions" \
  "$PREFIX/share/icons/hicolor/scalable/apps" "$PREFIX/share/icons/hicolor/symbolic/apps" "$PREFIX/share/doc" "$UNITS"
install -m 755 bin/otto "$PREFIX/bin/otto"
ln -sf otto "$PREFIX/bin/macos-harness"
install -m 755 "libexec/$NAME/otto-helper" "libexec/$NAME/otto-tower" "$PREFIX/libexec/$NAME/"
sed "s|^Exec=.*|Exec=$HELPER|" "share/applications/$APP_ID.desktop" > "$PREFIX/share/applications/$APP_ID.desktop"
rm -rf "${PREFIX:?}/share/gnome-shell/extensions/$UUID" "${PREFIX:?}/share/$NAME" "${PREFIX:?}/share/doc/$NAME"
cp -R "share/gnome-shell/extensions/$UUID" "$PREFIX/share/gnome-shell/extensions/"
cp -R "share/$NAME" "$PREFIX/share/"
cp -R "share/doc/$NAME" "$PREFIX/share/doc/"
install -m 644 "share/icons/hicolor/scalable/apps/$APP_ID.svg" "$PREFIX/share/icons/hicolor/scalable/apps/"
install -m 644 "share/icons/hicolor/symbolic/apps/$APP_ID-symbolic.svg" "$PREFIX/share/icons/hicolor/symbolic/apps/"
install -m 644 lib/systemd/user/otto.socket "$UNITS/otto.socket"
sed "s|^ExecStart=.*|ExecStart=$HELPER|" lib/systemd/user/otto.service > "$UNITS/otto.service"

if [[ "$SCOPE" == --user ]]; then
  systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now otto.socket >/dev/null 2>&1 || true
else
  systemctl --global enable otto.socket >/dev/null 2>&1 || true
fi
echo "Installed Otto in $PREFIX."
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Add $PREFIX/bin to your PATH, then run: otto doctor"; exit 0 ;;
esac
echo "Run: otto doctor"
