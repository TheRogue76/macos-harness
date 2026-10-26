#!/usr/bin/env bash
# Runs a command inside a private headless desktop: its own D-Bus session and accessibility bus,
# and a headless Mutter Wayland compositor with a virtual monitor, so test apps open nowhere on
# screen and the harness's helper is a separate one.
#
#   scripts/headless-desktop.sh <command> [arguments...]
#
# Needs dbus-run-session, at-spi2-core and mutter (the compositor alone, not a GNOME session).
# The compositor's log is copied to $HEADLESS_DESKTOP_LOG when that's set.
set -euo pipefail

if [ -z "${HEADLESS_DESKTOP_INNER:-}" ]; then
    runtime="$(mktemp -d /tmp/harness-desktop.XXXXXX)"
    chmod 700 "$runtime"
    trap 'rm -rf "$runtime" 2>/dev/null || true' EXIT
    status=0
    XDG_RUNTIME_DIR="$runtime" HEADLESS_DESKTOP_INNER=1 dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2) || status=$?
    exit "$status"
fi

command -v mutter >/dev/null || { echo "install mutter (apt install mutter, dnf install mutter, pacman -S mutter)" >&2; exit 1; }
compositor=mutter
log="$XDG_RUNTIME_DIR/compositor.log"
"$compositor" --headless --wayland --no-x11 --wayland-display harness-0 --virtual-monitor 1280x800 >"$log" 2>&1 &
compositor_pid=$!
finish() {
    kill "$compositor_pid" 2>/dev/null || true
    wait "$compositor_pid" 2>/dev/null || true
    if [ -n "${HEADLESS_DESKTOP_LOG:-}" ]; then cp "$log" "$HEADLESS_DESKTOP_LOG"; fi
}
trap finish EXIT
for _ in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/harness-0" ] && break
    if ! kill -0 "$compositor_pid" 2>/dev/null; then
        echo "$compositor exited:" >&2
        tail -20 "$log" >&2
        exit 1
    fi
    sleep 0.2
done
[ -S "$XDG_RUNTIME_DIR/harness-0" ] || { echo "$compositor didn't start in 20 s" >&2; tail -20 "$log" >&2; exit 1; }
unset DISPLAY
export WAYLAND_DISPLAY=harness-0 XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland
"$@"
