#!/usr/bin/env bash
# Saves how many windows Device Hub shows, or fails when it shows more than were saved, so a flow
# can catch simulator commands that open Device Hub windows they didn't need.
#
#   scripts/device-hub-windows.sh save
#   scripts/device-hub-windows.sh check
#
# Counts Device Hub's windows on screen through the window server, which needs no permission.
set -euo pipefail

state="${TMPDIR:-/tmp}/macos-harness-device-hub-windows"

count() {
  xcrun swift -e '
import CoreGraphics
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
print(windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "Device Hub" && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
' 2>/dev/null
}

case "${1:-}" in
  save)
    count > "$state"
    ;;
  check)
    saved=$(cat "$state")
    now=$(count)
    if [ "$now" -gt "$saved" ]; then
      echo "Device Hub went from $saved to $now windows" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 save|check" >&2
    exit 2
    ;;
esac
