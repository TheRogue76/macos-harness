#!/usr/bin/env bash
# Runs a command inside a private headless desktop: its own D-Bus session and accessibility bus,
# its own data, config and cache folders (so services the session starts, like the keyring, never
# touch the user's), and a headless Wayland compositor with a 1280x800 monitor, so test apps open
# nowhere on screen and the harness's helper is a separate one.
#
#   scripts/headless-desktop.sh <command> [arguments...]
#   HEADLESS_DESKTOP_COMPOSITOR=sway scripts/headless-desktop.sh <command> [arguments...]
#
# Needs dbus-run-session, at-spi2-core, and mutter (the compositor alone, not a GNOME session) or
# sway. The compositor's log is copied to $HEADLESS_DESKTOP_LOG when that's set.
set -euo pipefail

if [ -z "${HEADLESS_DESKTOP_INNER:-}" ]; then
    runtime="$(mktemp -d /tmp/harness-desktop.XXXXXX)"
    chmod 700 "$runtime"
    trap 'rm -rf "$runtime" 2>/dev/null || true' EXIT
    mkdir -p "$runtime/data" "$runtime/config" "$runtime/cache"
    export SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/swiftly}"
    export XDG_DATA_HOME="$runtime/data" XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache"
    status=0
    XDG_RUNTIME_DIR="$runtime" HEADLESS_DESKTOP_INNER=1 dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2) || status=$?
    exit "$status"
fi

compositor="${HEADLESS_DESKTOP_COMPOSITOR:-mutter}"
command -v "$compositor" >/dev/null || { echo "install $compositor (apt install $compositor, dnf install $compositor, pacman -S $compositor)" >&2; exit 1; }
log="$XDG_RUNTIME_DIR/compositor.log"
case "$compositor" in
    mutter)
        mutter --headless --wayland --no-x11 --wayland-display harness-0 --virtual-monitor 1280x800 >"$log" 2>&1 &
        ;;
    sway)
        printf 'output * resolution 1280x800\nxwayland disable\n' > "$XDG_RUNTIME_DIR/sway.conf"
        WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WAYLAND_DISPLAY= sway --config "$XDG_RUNTIME_DIR/sway.conf" >"$log" 2>&1 &
        ;;
    *)
        echo "unknown compositor $compositor; use mutter or sway" >&2
        exit 1
        ;;
esac
compositor_pid=$!
finish() {
    kill "$compositor_pid" 2>/dev/null || true
    wait "$compositor_pid" 2>/dev/null || true
    if [ -n "${HEADLESS_DESKTOP_LOG:-}" ]; then cp "$log" "$HEADLESS_DESKTOP_LOG"; fi
}
trap finish EXIT
display() {
    if [ "$compositor" = sway ]; then ls "$XDG_RUNTIME_DIR" | grep -m1 -E '^wayland-[0-9]+$'; else echo harness-0; fi
}
for _ in $(seq 1 100); do
    [ -n "$(display)" ] && [ -S "$XDG_RUNTIME_DIR/$(display)" ] && break
    if ! kill -0 "$compositor_pid" 2>/dev/null; then
        echo "$compositor exited:" >&2
        tail -20 "$log" >&2
        exit 1
    fi
    sleep 0.2
done
[ -n "$(display)" ] && [ -S "$XDG_RUNTIME_DIR/$(display)" ] || { echo "$compositor didn't start in 20 s" >&2; tail -20 "$log" >&2; exit 1; }
unset DISPLAY
WAYLAND_DISPLAY="$(display)"
export WAYLAND_DISPLAY XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland
if [ "$compositor" = sway ]; then
    for _ in $(seq 1 50); do
        SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)"
        [ -n "$SWAYSOCK" ] && break
        sleep 0.1
    done
    export SWAYSOCK
fi
"$@"
