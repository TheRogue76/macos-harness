#!/usr/bin/env bash
# Runs a command inside a private headless desktop: its own D-Bus session and accessibility bus,
# its own data, config, cache and state folders (so services the session starts, like the keyring,
# and the harness's own helper never touch the user's), and a headless Wayland compositor with a 1280x800 monitor, so test apps open
# nowhere on screen and the harness's helper is a separate one.
#
#   scripts/headless-desktop.sh <command> [arguments...]
#   HEADLESS_DESKTOP_COMPOSITOR=sway scripts/headless-desktop.sh <command> [arguments...]
#   HEADLESS_DESKTOP_COMPOSITOR=gnome-shell scripts/headless-desktop.sh <command> [arguments...]
#   HEADLESS_DESKTOP_COMPOSITOR=kwin_wayland scripts/headless-desktop.sh <command> [arguments...]
#
# Needs dbus-run-session, at-spi2-core, and mutter (the compositor alone), sway, gnome-shell (a
# whole GNOME session, run with a private home too, with the harness's Shell extension enabled,
# and PipeWire, which GNOME's remote desktop needs, when it's installed), or kwin_wayland (KDE's
# compositor, with XDG_CURRENT_DESKTOP=KDE so KDE's portals answer, PipeWire, which its remote
# desktop needs, and its checks of privileged clients off, as nobody's there to approve them).
# The compositor's log is copied to $HEADLESS_DESKTOP_LOG when that's set, and PipeWire's next to it.
set -euo pipefail

if [ -z "${HEADLESS_DESKTOP_INNER:-}" ]; then
    runtime="$(mktemp -d /tmp/harness-desktop.XXXXXX)"
    chmod 700 "$runtime"
    trap 'rm -rf "$runtime" 2>/dev/null || true' EXIT
    mkdir -p "$runtime/data" "$runtime/config" "$runtime/cache" "$runtime/state" "$runtime/home"
    export SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/swiftly}"
    if [ "${HEADLESS_DESKTOP_COMPOSITOR:-mutter}" = gnome-shell ]; then
        export HEADLESS_DESKTOP_REPO="$(cd "$(dirname "$0")/.." && pwd)" HOME="$runtime/home"
    fi
    export XDG_DATA_HOME="$runtime/data" XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache" XDG_STATE_HOME="$runtime/state"
    status=0
    XDG_RUNTIME_DIR="$runtime" HEADLESS_DESKTOP_INNER=1 dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2) || status=$?
    for pid in $(pgrep -u "$(id -u)"); do
        if { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$runtime"; then kill "$pid" 2>/dev/null || true; fi
    done
    exit "$status"
fi

compositor="${HEADLESS_DESKTOP_COMPOSITOR:-mutter}"
start_pipewire() {
    if command -v pipewire >/dev/null; then
        pipewire >"$XDG_RUNTIME_DIR/pipewire.log" 2>&1 </dev/null &
        helpers+=("$!")
        if command -v wireplumber >/dev/null; then
            wireplumber >"$XDG_RUNTIME_DIR/wireplumber.log" 2>&1 </dev/null &
            helpers+=("$!")
        fi
        for _ in $(seq 1 50); do
            [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break
            sleep 0.1
        done
    fi
}
grant() {
    for _ in $(seq 1 50); do
        gdbus call --session -d org.freedesktop.impl.portal.PermissionStore -o /org/freedesktop/impl/portal/PermissionStore \
            -m org.freedesktop.impl.portal.PermissionStore.SetPermission "$1" true "$2" '' "['yes']" >/dev/null 2>&1 && break
        sleep 0.2
    done
}
helpers=()
command -v "$compositor" >/dev/null || { echo "install $compositor (apt install $compositor, dnf install $compositor, pacman -S $compositor)" >&2; exit 1; }
log="$XDG_RUNTIME_DIR/compositor.log"
case "$compositor" in
    mutter)
        mutter --headless --wayland --no-x11 --wayland-display harness-0 --virtual-monitor 1280x800 >"$log" 2>&1 &
        ;;
    gnome-shell)
        extension="${HEADLESS_DESKTOP_REPO:?}/packaging/linux/gnome-extension/macos-harness@therogue76.github.io"
        mkdir -p "$XDG_DATA_HOME/gnome-shell/extensions"
        cp -r "$extension" "$XDG_DATA_HOME/gnome-shell/extensions/"
        gsettings set org.gnome.shell disable-user-extensions false
        gsettings set org.gnome.shell enabled-extensions "['macos-harness@therogue76.github.io']"
        gsettings set org.gnome.desktop.interface toolkit-accessibility true
        start_pipewire
        gnome-shell --headless --wayland --no-x11 --wayland-display harness-0 --virtual-monitor 1280x800 >"$log" 2>&1 &
        grant screenshot screenshot &
        ;;
    kwin_wayland)
        export XDG_CURRENT_DESKTOP=KDE KDE_FULL_SESSION=true QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
        dbus-update-activation-environment XDG_CURRENT_DESKTOP KDE_FULL_SESSION QT_LINUX_ACCESSIBILITY_ALWAYS_ON \
            WAYLAND_DISPLAY=harness-0 XDG_SESSION_TYPE=wayland
        { grant screenshot screenshot; grant kde-authorized remote-desktop; } &
        start_pipewire
        KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 kwin_wayland --virtual --no-lockscreen --no-global-shortcuts --no-kactivities --socket harness-0 --width 1280 --height 800 >"$log" 2>&1 &
        ;;
    sway)
        printf 'output * resolution 1280x800\nxwayland disable\n' > "$XDG_RUNTIME_DIR/sway.conf"
        WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WAYLAND_DISPLAY= sway --config "$XDG_RUNTIME_DIR/sway.conf" >"$log" 2>&1 &
        ;;
    *)
        echo "unknown compositor $compositor; use mutter, sway, gnome-shell or kwin_wayland" >&2
        exit 1
        ;;
esac
compositor_pid=$!
finish() {
    for helper in "${helpers[@]}"; do kill "$helper" 2>/dev/null || true; done
    kill "$compositor_pid" 2>/dev/null || true
    wait "$compositor_pid" 2>/dev/null || true
    if [ -n "${HEADLESS_DESKTOP_LOG:-}" ]; then
        cp "$log" "$HEADLESS_DESKTOP_LOG"
        for extra in pipewire wireplumber; do
            if [ -f "$XDG_RUNTIME_DIR/$extra.log" ]; then cp "$XDG_RUNTIME_DIR/$extra.log" "$(dirname "$HEADLESS_DESKTOP_LOG")/"; fi
        done
    fi
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
dbus-update-activation-environment WAYLAND_DISPLAY XDG_SESSION_TYPE
if [ "$compositor" = sway ]; then
    for _ in $(seq 1 50); do
        SWAYSOCK="$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)"
        [ -n "$SWAYSOCK" ] && break
        sleep 0.1
    done
    export SWAYSOCK
fi
"$@"
