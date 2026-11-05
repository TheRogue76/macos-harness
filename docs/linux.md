# Linux

Otto runs on Linux desktops under Wayland: GNOME, KDE Plasma, and Sway and other wlroots
compositors. Agents use the same commands and MCP tools as on the Mac. The helper reads
apps through the accessibility bus (AT-SPI), and the desktop's own interfaces show it the
windows and let it take screenshots and use the mouse and keyboard. X11 sessions aren't
supported.

It runs on x86_64 and arm64, and is tested on Ubuntu, Fedora and Arch.

## Install

Each [release](https://github.com/TheRogue76/otto-harness/releases) has `otto-harness`
packages for x86_64 and arm64 (aarch64):

```bash
sudo apt install ./otto-harness_*_amd64.deb             # Ubuntu 24.04 or later, Debian 13
sudo dnf install ./otto-harness-*.x86_64.rpm            # Fedora
brew trust therogue76/tap && brew install therogue76/tap/otto-harness   # Homebrew
```

Elsewhere, such as Arch, unpack the tarball and run its `install.sh`, which installs into
`~/.local` (or `--prefix /usr/local` with `sudo`); `install.sh --uninstall` removes it.
Pre-releases are `otto-harness@rc` in the tap. The packages start the helper through
systemd when you first use `otto`, and bring the GNOME extension along; GNOME loads it
after you log out and back in.

### From a checkout

Install Swift with [swiftly](https://www.swift.org/install/linux/), then the libraries:

```bash
sudo apt install libgtk-4-dev libadwaita-1-dev at-spi2-core tesseract-ocr   # Ubuntu, Debian
sudo dnf install gtk4-devel libadwaita-devel at-spi2-core tesseract          # Fedora
sudo pacman -S gtk4 libadwaita at-spi2-core tesseract tesseract-data-eng     # Arch
```

GTK 4 and libadwaita are for the Control Tower panel; without them the helper builds and
runs with a tray menu instead. Tesseract is for text recognition (`--ocr`). Recording
needs GStreamer (`gstreamer1.0-tools` and its good plugins, and `gstreamer1.0-pipewire`
on GNOME and KDE).

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/otto .build/release/otto-helper ~/.local/bin/
cp .build/release/otto-tower ~/.local/bin/    # when GTK 4 and libadwaita were there to build it
otto doctor
```

Keep the three programs in one folder: `otto` starts `otto-helper` from beside itself, and
the helper opens `otto-tower` from beside itself. `doctor` starts the helper and says what's
missing. Then grant what the desktop asks for, as in
[Getting started](getting-started.md#on-linux), and connect your agent with
`otto setup claude` (or codex, cursor, gemini or opencode).

On GNOME, from a checkout, `scripts/install-gnome-extension.sh` installs the Otto
extension; log out and back in once so GNOME loads it.

## What works

On desktop apps: `apps`, `windows` and `window`, `launch` and `quit`, `snapshot`, `find`,
`read`, `collect`, `wait`, menus and status icons in the tray (`menu`, `menu-select`
with `--extras`), element actions (`press`, `set-value`, `focus`, `select`, `increment`
and the rest), `type`, `paste` and `key`, the pointer (`click`, `hover`, `drag`, `scroll`),
`screenshot`, text recognition, `record`, the clipboard, `steps` and flows. Android
emulators and phones work as on the Mac (see [Android](android.md)).

`sim` and `build` need macOS: iOS Simulators and Xcode only run there.

Some things differ from the Mac:

- **Real input.** Clicks and keys go through the desktop's remote desktop interface, so
  they move your pointer; there are no background clicks.
- **Screenshots of one window** show that window alone on GNOME and KDE. On Sway they show
  the screen area the window covers, and a notice names any other app's window in front.
- **Some apps build their accessibility tree only when asked**, Chromium and Electron
  among them. `launch` starts them with it switched on; for one that's already running,
  `doctor` and the error say what to do.
- **GTK 4 lists** don't scroll to an item when asked, so `scroll-to` fails in them and
  `collect` stops at what shows; use `scroll` instead. Chromium's lists work.
- **Dragging into another window** isn't supported yet.
- **The stop shortcut** is bound through the desktop on GNOME and KDE. On Sway, bind
  `otto stop` yourself: `bindsym Ctrl+Alt+Mod4+period exec otto stop`.

## Where things are

| What | Where |
|---|---|
| Policy | `~/.config/otto/policy.yaml` |
| Logs and the journal | `~/.local/state/otto/` |
| The helper's socket | `$XDG_RUNTIME_DIR/otto/release.sock` (`dev.sock` for a dev build) |
| Start at login | `~/.config/autostart/io.github.therogue76.Otto.desktop` |
| The GNOME extension | `otto@therogue76.github.io` |

Packages also install `otto.socket` and `otto.service` for systemd, so the first command
starts the helper. Without them, `otto` starts the helper in its own session.

## Coming from an earlier build

Linux builds before 2.0 were called macOS Harness. A new helper takes over what an old one
left: it moves the folders from `macos-harness` to `otto` and its Start at login entry to
the new app ID. On KDE it replaces the old window script. On GNOME, `otto permissions
grant` removes the old macOS Harness extension once Otto's runs.

GNOME and KDE remember the stop shortcut per app, so allow it again when
`otto permissions grant` asks. Screenshot and remote desktop answers carry over. Delete the
old `macos-harness-helper` and `macos-harness-tower` programs from where you copied them.
