#!/usr/bin/env bash
# M10 acceptance: several agent sessions at once, the others played by the helper's review
# commands (made-up sessions) next to the session running this script. Real-input steps move
# your cursor and bring the fixture and TextEdit to the front, so keep your hands off the mouse
# and keyboard while it runs. It makes two TextEdit documents in ~/macos-harness-sandbox and
# deletes them at the end. Run: scripts/acceptance-m10.sh
set -uo pipefail
H="${MACOS_HARNESS:-macos-harness-dev}"
FIXTURE="Harness Fixture"
SANDBOX="$HOME/macos-harness-sandbox"
MINE="$SANDBOX/m10-mine.txt"
THEIRS="$SANDBOX/m10-theirs.txt"
OUT="$(mktemp -d)"
failures=0
# check <name> <condition command…>: prints PASS or FAIL for the condition.
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; failures=$((failures + 1)); fi
}
# now: seconds since the epoch, with fractions.
now() { python3 -c 'import time; print(time.time())'; }
# between <low> <high> <seconds>: whether low <= seconds <= high.
between() { python3 -c "import sys; sys.exit(0 if $1 <= $3 <= $2 else 1)"; }
# mcp_act <json arguments>: calls the MCP act tool and prints its text result.
mcp_act() {
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"acceptance","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"act\",\"arguments\":$1}}" \
    | (cat; sleep 5) | $H mcp 2>/dev/null | tail -1 \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"]["content"][0]["text"])'
}
textedit_was_running=$($H apps 2>/dev/null | grep -c '^TextEdit ')

echo "== Sessions told apart"
check "doctor names this session by its folder" bash -c "$H doctor | grep -q 'Caller: .* · '"
check "a made-up second session of this agent joins the panel" $H spike session-demo

echo "== Window claims"
$H quit "$FIXTURE" >/dev/null 2>&1
open -g "$HOME/Applications/$FIXTURE.app"
$H wait --id increment-button -a "$FIXTURE" --timeout 10 >/dev/null
fixture=$($H windows -a "$FIXTURE" | awk 'NR == 1 { print $1 }')
claimed=$(now)
$H spike claim-demo "$fixture" >/dev/null
check "windows marks the window another session holds" bash -c "$H windows -a '$FIXTURE' | grep -q 'in use by Demo Agent · demo-project'"
check "reading that window still works" $H snapshot -a "$FIXTURE" --max-nodes 5
started=$(now)
$H press --id increment-button -a "$FIXTURE" --json > "$OUT/claimed.json" 2>&1
waited=$(python3 -c "print($(now) - $started)")
check "acting there is refused with error 1006" grep -q '"code" : 1006' "$OUT/claimed.json"
check "…after waiting about 5 s for the claim to end" between 4 9 "$waited"
check "…naming who works there" grep -q 'Demo Agent · demo-project is working in' "$OUT/claimed.json"
sleep "$(python3 -c "print(max(0, 31 - ($(now) - $claimed)))")"
check "once the claim lapses, acting works" $H press --id increment-button -a "$FIXTURE" --no-diff
check "and this session's claim now refuses the made-up one" bash -c "! $H spike claim-demo $fixture"

echo "== Keys and menu commands in another session's window"
printf 'Mine\n' > "$MINE"
printf 'Theirs\n' > "$THEIRS"
open -g -a TextEdit "$MINE"
sleep 2
open -g -a TextEdit "$THEIRS"
sleep 2
mine=$($H windows -a TextEdit | awk '/"m10-mine.txt"/ { print $1 }')
theirs=$($H windows -a TextEdit | awk '/"m10-theirs.txt"/ { print $1 }')
field=$($H find -a TextEdit -w "$mine" --role textarea | awk 'NR == 2 { print $1 }')
$H spike claim-demo "$theirs" >/dev/null
mcp_act "{\"app\":\"TextEdit\",\"window\":$mine,\"action\":\"key\",\"value\":\"cmd+a\",\"ref\":\"$field\"}" > "$OUT/key.txt" 2>&1
check "a key aimed at this session's window, which would land in theirs, is refused" grep -q 'would go to TextEdit' "$OUT/key.txt"
check "a menu command acting on their focused window is refused" bash -c "! $H menu-select -a TextEdit Edit 'Select All' --no-diff"
check "typing into a field of this session's own window works" $H type " ok" --into "$field" -a TextEdit -w "$mine" --no-diff
check "…and their document is untouched" bash -c "$H find -a TextEdit -w $theirs --role textarea | grep -q '\"Theirs'"

echo "== Taking turns with the mouse and keyboard"
$H spike turn-demo >/dev/null
started=$(now)
$H click --id increment-button -a "$FIXTURE" > "$OUT/turn.txt" 2>&1
waited=$(python3 -c "print($(now) - $started)")
check "a click waits its turn behind another session" grep -q 'Waited .* for Demo Agent · demo-project' "$OUT/turn.txt"
check "…for most of that session's 10 s" between 6 25 "$waited"
check "…and then clicks" grep -q 'clicked button “Increment”' "$OUT/turn.txt"
check "the front goes back to the app that had it" grep -q 'Gave the front back to' "$OUT/turn.txt"

echo "== A context menu stays open and keeps the turn"
$H click --right --role textarea -a TextEdit -w "$mine" > "$OUT/menu.txt" 2>&1
copy=$(awk '/menuItem "Copy"/ { print $2; exit }' "$OUT/menu.txt")
check "right-click lists the context menu as refs" test -n "$copy"
sleep 5
check "an item can still be chosen 5 s later" $H press "$copy" -a TextEdit -w "$mine" --no-diff
started=$(now)
$H click --id increment-button -a "$FIXTURE" --no-diff >/dev/null 2>&1
check "once the menu closed, the next click didn't wait for it" between 0 8 "$(python3 -c "print($(now) - $started)")"

echo "== Cleaning up"
$H window close -a TextEdit -w "$theirs" >/dev/null 2>&1
$H window close -a TextEdit -w "$mine" >/dev/null 2>&1
sleep 1
for button in $($H find Delete -a TextEdit --role button 2>/dev/null | awk '/DontSaveButton/ { print $1 }'); do
  $H press "$button" -a TextEdit --no-diff >/dev/null 2>&1
done
[[ "$textedit_was_running" == 0 ]] && $H quit TextEdit >/dev/null 2>&1
rm -f "$MINE" "$THEIRS"
$H quit "$FIXTURE" >/dev/null 2>&1
rm -rf "${OUT:?}"

echo
if [[ $failures -eq 0 ]]; then echo "All M10 checks passed."; else echo "$failures M10 checks failed."; fi
exit $failures
