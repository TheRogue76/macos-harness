#!/usr/bin/env bash
# Packs the macOS Harness GNOME Shell extension into the zip extensions.gnome.org takes, with
# the licence, and prints where it is. Upload it at https://extensions.gnome.org/upload/.
#
#   scripts/pack-gnome-extension.sh [out-dir]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
uuid="macos-harness@therogue76.github.io"
out="${1:-$root/.build/gnome-extension}"
mkdir -p "$out"
gnome-extensions pack --force --out-dir="$out" --extra-source="$root/LICENSE" \
    --extra-source="$root/packaging/linux/gnome-extension/$uuid/icons" "$root/packaging/linux/gnome-extension/$uuid"
echo "$out/$uuid.shell-extension.zip"
