---
type: Environment
title: Linux dev machine
description: OS, desktop, Swift toolchain and Linux libraries on the owner's Linux desktop used for 2.0 work.
tags: [environment, linux, wayland, gnome, swift, swiftly]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
stale_after: 2026-12-25T00:00:00Z
sources:
  - id: probe
    resource: uname, /etc/os-release, swiftly, swift --version, busctl and dpkg, run from a Claude Code shell on 2026-10-25
---

# Machine

- Ubuntu 26.04.1 LTS, kernel 7.0, x86_64, 16 cores, 59 GB RAM.[^probe]
- GNOME Shell 50.1 on Wayland (`XDG_SESSION_TYPE=wayland`).
- No passwordless sudo: system packages need the owner.

# Swift

- Swift 6.4.1 installed per user with swiftly into
  `~/.local/share/swiftly`; `~/.profile` sources its `env.sh`. A fresh
  shell may need `. ~/.local/share/swiftly/env.sh`.
- `sourcekit-lsp` is on the path for editors.
- swiftly asked for `binutils-gold gnupg2 libpython3-dev libz3-dev`. They
  weren't installed when this was written, and packages still built, ran and
  tested.

# Libraries present

Runtime libraries for libatspi, libei, PipeWire, xkbcommon, GTK 4.22,
libadwaita 1.9, XTest and wl-clipboard are installed. The `-dev` packages
(headers and pkg-config files) for them aren't, and are needed once the C
shim targets exist.
