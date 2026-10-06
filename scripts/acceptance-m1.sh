#!/usr/bin/env bash
# M1 acceptance: snapshot, find and screenshot every tier A app, then summarize.
# Needs the dev helper installed with both permissions granted (`macos-harness-dev doctor`).
# MACOS_HARNESS picks another CLI, such as the release `macos-harness`.
set -euo pipefail
H="${MACOS_HARNESS:-macos-harness-dev}"
SANDBOX="$HOME/macos-harness-sandbox"
OUT="${TMPDIR:-/tmp}/macos-harness-acceptance"
mkdir -p "$SANDBOX" "$OUT"
[[ -f "$SANDBOX/spike.txt" ]] || printf 'macos-harness test document.\n' > "$SANDBOX/spike.txt"
[[ -f "$SANDBOX/spike.pdf" ]] || printf 'Page one.\n\fPage two.\n' | /usr/sbin/cupsfilter -i text/plain /dev/stdin > "$SANDBOX/spike.pdf" 2>/dev/null

APPS=(Calculator TextEdit Preview "Font Book" Chess Clock Weather Maps Stocks "Harness Fixture")
for app in "${APPS[@]}"; do
  case "$app" in
    TextEdit) open -g -a TextEdit "$SANDBOX/spike.txt" ;;
    Preview) open -g -a Preview "$SANDBOX/spike.pdf" ;;
    "Harness Fixture") open -g "$HOME/Applications/Harness Fixture.app" ;;
    *) open -g -a "$app" ;;
  esac
done
sleep 5

printf '%-16s %8s %6s %6s %9s %10s %s\n' app shown read ms visible-ui screenshot notes
for app in "${APPS[@]}"; do
  file="$OUT/$(echo "$app" | tr ' ' '-').png"
  snapshot=$($H snapshot -a "$app" --json 2>&1) || { printf '%-16s FAILED: %s\n' "$app" "$snapshot"; continue; }
  shot=$($H screenshot -a "$app" --labels --out "$file" --json 2>&1) || shot='{"result":{"width":0,"height":0}}'
  python3 - "$app" "$snapshot" "$shot" <<'PY'
import json, sys
app, snap, shot = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
interactive = {"AXButton","AXCheckBox","AXRadioButton","AXTextField","AXTextArea","AXPopUpButton","AXMenuButton",
               "AXSlider","AXComboBox","AXLink","AXIncrementor","AXDisclosureTriangle","AXSearchField","AXTabGroup"}
def walk(n):
    yield n
    for c in n["children"]: yield from walk(c)
nodes = list(walk(snap["root"]))
ui = [n for n in nodes if n["role"] in interactive or [a for a in n["actions"] if a != "AXCancel"]]
missing = [n for n in ui if not n.get("hit") and n["role"] != "AXWindow"]
notes = [x["kind"] for x in snap["notices"] if x["kind"] not in ("notFrontmost",)]
if missing: notes.append(f"{len(missing)} without click point")
r = shot["result"]
print(f'{app:<16} {snap["shownCount"]:>8} {snap["readCount"]:>6} {snap["milliseconds"]:>6} {len(ui):>9} {r["width"]:>5}x{r["height"]:<5} {",".join(notes)}')
PY
done
echo "Labeled screenshots: $OUT"
