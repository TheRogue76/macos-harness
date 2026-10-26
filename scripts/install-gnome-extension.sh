#!/usr/bin/env bash
# Installs and enables the macOS Harness GNOME Shell extension, which tells the harness where
# windows are and brings them forward. On Wayland, GNOME Shell sees a newly installed extension
# only after logging out and back in; the script says so when that's needed.
#
#   scripts/install-gnome-extension.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
uuid="macos-harness@therogue76.github.io"
target="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$uuid"
mkdir -p "$target"
cp "$root/packaging/linux/gnome-extension/$uuid/"* "$target/"
if gnome-extensions enable "$uuid" 2>/dev/null; then
    echo "Enabled $uuid."
else
    echo "Installed $uuid. Log out and back in, then run: gnome-extensions enable $uuid"
fi
