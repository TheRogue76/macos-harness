#!/usr/bin/env bash
# M3 acceptance: real input on the fixture and in Finder, then the stop hotkey. It moves your
# cursor and brings apps to the front, so keep your hands off the mouse and keyboard while it
# runs. It ends with every agent stopped; resume them from the menu bar panel.
set -uo pipefail
H="${MACOS_HARNESS:-macos-harness-dev}"
FIXTURE="Harness Fixture"
FINDER_TEST="$HOME/macos-harness-sandbox/finder-test"
OUT="$(mktemp -d)"
failures=0
# check <name> <condition command…>: prints PASS or FAIL for the condition.
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; failures=$((failures + 1)); fi
}

echo "== Fixture: click, drag, hover, right-click, scroll, real typing"
$H quit "$FIXTURE" >/dev/null 2>&1
open "$HOME/Applications/$FIXTURE.app"
$H wait --id click-canvas -a "$FIXTURE" --timeout 10 >/dev/null
$H click --id click-canvas -a "$FIXTURE" --no-diff >/dev/null
check "Click lands on the canvas center (y 35 of 70)" bash -c "$H find --id click-result -a '$FIXTURE' | grep -Eq 'Clicked at [0-9]+,3[45]'"
$H drag --id drag-source --to-id drop-target -a "$FIXTURE" --no-diff >/dev/null
check "Drag and drop delivers the token" bash -c "$H find --id drop-target -a '$FIXTURE' | grep -q 'Dropped: token'"
$H hover --id hover-target -a "$FIXTURE" --no-diff >/dev/null
check "Hover is seen" bash -c "$H find --id hover-target -a '$FIXTURE' | grep -q 'Hovering: yes'"
$H click --id context-target --right -a "$FIXTURE" > "$OUT/menu.txt" 2>&1
item=$(awk '/menuItem "Mark as done"/ { print $2; exit }' "$OUT/menu.txt")
check "Right-click lists the context menu as refs" test -n "$item"
[[ -n "$item" ]] && $H press "$item" -a "$FIXTURE" --no-diff >/dev/null
check "Context menu item works" bash -c "$H find --id context-result -a '$FIXTURE' | grep -q 'Chosen: done'"
check "Row 1 starts in view" bash -c "$H snapshot -a '$FIXTURE' | grep -q 'id=row-1 '"
$H scroll --id rows-scroll --down 200 -a "$FIXTURE" --no-diff >/dev/null
check "Scrolling moves the rows" bash -c "! $H snapshot -a '$FIXTURE' | grep -q 'id=row-1 '"
$H focus --id name-field -a "$FIXTURE" --no-diff >/dev/null
$H type "first" --real -a "$FIXTURE" --no-diff >/dev/null
$H key cmd+a --real -a "$FIXTURE" --no-diff >/dev/null
$H type "Real keys" --real -a "$FIXTURE" --no-diff >/dev/null
check "Real typing replaces a ⌘A selection" bash -c "$H find --id name-field -a '$FIXTURE' | grep -q '\"Real keys\"'"

echo "== Finder: move a file between sandbox folders by dragging"
mkdir -p "$FINDER_TEST/done"
rm -f "$FINDER_TEST/done/move-me.txt" "$FINDER_TEST/inbox/move-me.txt"
echo "moved by macos-harness" > "$FINDER_TEST/move-me.txt"
$H launch Finder --open "$FINDER_TEST" >/dev/null
sleep 1
$H menu-select -a Finder View "as List" --no-diff >/dev/null
$H wait --text move-me.txt -a Finder --timeout 5 >/dev/null
$H drag --text move-me.txt --role textfield --to-text done --to-role textfield -a Finder --no-diff >/dev/null
sleep 0.5
check "move-me.txt is in done/" test -f "$FINDER_TEST/done/move-me.txt"
check "…and no longer at the top level" test ! -f "$FINDER_TEST/move-me.txt"
$H click --text done --role textfield --exact --right -a Finder > "$OUT/finder-menu.txt" 2>&1
check "Finder's context menu lists Get Info" grep -q 'menuItem "Get Info"' "$OUT/finder-menu.txt"
check "…without separators or ⌥ alternates" bash -c "! grep -Eq 'menuItem disabled actions|Paste Item Exactly' '$OUT/finder-menu.txt'"
$H key escape --real -a Finder --no-diff >/dev/null
$H window close -a Finder >/dev/null

echo "== Stop hotkey halts a gesture partway (leaves all agents stopped)"
open "$HOME/Applications/$FIXTURE.app"
$H wait --id drag-source -a "$FIXTURE" --timeout 5 >/dev/null
$H drag --id drag-source --to-id drop-target --duration 4 -a "$FIXTURE" > "$OUT/stop.txt" 2>&1 &
drag=$!
sleep 1.5
$H spike press-stop-hotkey >/dev/null
wait $drag
check "The drag stopped partway" grep -q "stopped this agent partway" "$OUT/stop.txt"

echo
echo "Every agent is stopped now: resume from the macOS Harness menu bar panel."
if [[ $failures -eq 0 ]]; then echo "All M3 acceptance checks passed."; else echo "$failures check(s) failed."; fi
rm -rf "$OUT"
exit $failures
