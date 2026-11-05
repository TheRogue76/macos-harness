#!/usr/bin/env bash
# Installs and enables the Otto GNOME Shell extension, which tells the harness where windows are
# and brings them forward, and removes the macOS Harness extension it replaces from this user's
# extensions. On Wayland, GNOME Shell sees a newly installed extension only after logging out and
# back in; the script says so when that's needed.
#
#   scripts/install-gnome-extension.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
uuid="otto@therogue76.github.io"
legacy="macos-harness@therogue76.github.io"
extensions="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
target="$extensions/$uuid"
if [[ -d "$extensions/$legacy" ]]; then
    gnome-extensions disable "$legacy" 2>/dev/null || true
    rm -rf "${extensions:?}/$legacy"
    echo "Removed $legacy, which $uuid replaces."
fi
mkdir -p "$target"
cp -r "$root/packaging/linux/gnome-extension/$uuid/"* "$target/"
if gnome-extensions enable "$uuid" 2>/dev/null; then
    echo "Enabled $uuid."
else
    echo "Installed $uuid. Log out and back in, then run: gnome-extensions enable $uuid"
fi
