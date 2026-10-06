#!/usr/bin/env bash
# M2 acceptance: the four roadmap tasks, done without real input (no cursor movement).
# TextEdit and Preview are brought to the front for menu commands; the harness waits if
# you're typing. Files go to ~/macos-harness-sandbox only.
set -uo pipefail
H=macos-harness
SANDBOX="$HOME/macos-harness-sandbox"
mkdir -p "$SANDBOX"
[[ -f "$SANDBOX/spike.pdf" ]] || printf 'Page one.\n\fPage two.\n\fPage three.\n' | /usr/sbin/cupsfilter -i text/plain /dev/stdin > "$SANDBOX/spike.pdf" 2>/dev/null
failures=0
check() {  # check <name> <condition command…>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; failures=$((failures + 1)); fi
}

echo "== Calculator: 12 × 34"
$H launch Calculator >/dev/null
# The clear key reads "Clear" while there's an entry and "All Clear" after; press it until it's All Clear.
for _ in 1 2; do $H press --text Clear --role button -a Calculator --no-diff >/dev/null; done
for id in One Two Multiply Three Four Equals; do $H press --id "$id" -a Calculator --no-diff >/dev/null; done
check "Calculator shows 408" bash -c "$H snapshot -a Calculator | grep -q 'text \"408\"'"

echo "== TextEdit: write, bold, save to the sandbox"
name="m2-acceptance-$(date +%H%M%S)"
$H launch TextEdit >/dev/null
$H menu-select -a TextEdit File New >/dev/null   # with the diff, so the new window has settled
$H wait --role textarea -a TextEdit --timeout 5 >/dev/null
$H type "Written by an agent through macos-harness, without touching the mouse." -a TextEdit --no-diff >/dev/null
$H menu-select -a TextEdit Edit "Select All" --no-diff >/dev/null
$H snapshot -a TextEdit | grep -q 'checkbox "bold" on' || $H menu-select -a TextEdit Format Font Bold --no-diff >/dev/null
check "Text is bold" bash -c "$H snapshot -a TextEdit | grep -q 'checkbox \"bold\" on'"
$H menu-select -a TextEdit File "Save…" --no-diff >/dev/null
$H key cmd+shift+g -a TextEdit --no-diff >/dev/null   # goes to the save panel's own process
$H wait --id PathTextField -a TextEdit --timeout 5 >/dev/null
$H set-value --id PathTextField -v "$SANDBOX/" -a TextEdit --no-diff >/dev/null
$H key return -a TextEdit --no-diff >/dev/null
sleep 0.5
$H set-value --id saveAsNameTextField -v "$name" -a TextEdit --no-diff >/dev/null
$H press --id OKButton -a TextEdit --no-diff >/dev/null
$H wait --id save-panel --gone -a TextEdit --timeout 5 >/dev/null
check "Saved $name.rtf in the sandbox" test -f "$SANDBOX/$name.rtf"
check "Saved file is bold" grep -q "Helvetica-Bold" "$SANDBOX/$name.rtf"
[[ -f "$SANDBOX/$name.rtf" ]] && $H window close -a TextEdit >/dev/null

echo "== Preview: page through a PDF"
$H launch Preview --open "$SANDBOX/spike.pdf" >/dev/null
sleep 1
$H menu-select -a Preview Go Down --no-diff >/dev/null
$H menu-select -a Preview Go Down --no-diff >/dev/null
check "Preview moved past page 1" bash -c "$H windows -a Preview | grep -q 'spike.pdf – Page [23] of'"

echo "== Weather: switch cities"
$H launch Weather >/dev/null
$H press --text Stockholm --role button -a Weather --no-diff >/dev/null
check "Weather shows Stockholm" bash -c "$H windows -a Weather | grep -q '\"Stockholm\"'"
$H press --text "My Location" --role button -a Weather --no-diff >/dev/null

echo
if [[ $failures -eq 0 ]]; then echo "All M2 acceptance checks passed."; else echo "$failures check(s) failed."; fi
exit $failures
