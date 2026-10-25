#!/usr/bin/env bash
# Builds the GTK 4 fixture app and installs it with a desktop entry named "Harness Fixture", which
# keeps it out of app menus (NoDisplay), so `launch: Harness Fixture` finds it.
#
#   scripts/build-linux-fixture.sh
#
# Needs Swift and GTK 4's headers (libgtk-4-dev, gtk4-devel or gtk4). Installs into
# $XDG_DATA_HOME (~/.local/share): macos-harness/fixtures/harness-fixture and
# applications/io.github.therogue76.HarnessFixture.desktop.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/fixtures/linux"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
swift build --package-path "$package" -c debug --quiet 2> >(grep -v "prohibited flag" >&2)
binary="$(swift build --package-path "$package" -c debug --show-bin-path)/harness-fixture"
install -d "$data/macos-harness/fixtures" "$data/applications"
install -m 755 "$binary" "$data/macos-harness/fixtures/harness-fixture"
cat > "$data/applications/io.github.therogue76.HarnessFixture.desktop" <<ENTRY
[Desktop Entry]
Type=Application
Name=Harness Fixture
Comment=Test app for macOS Harness
Exec=$data/macos-harness/fixtures/harness-fixture
NoDisplay=true
ENTRY
echo "$data/macos-harness/fixtures/harness-fixture"
