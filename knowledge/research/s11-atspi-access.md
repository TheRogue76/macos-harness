---
type: Analysis
title: "S11: reading AT-SPI trees fast"
description: libatspi's one-call-per-property walk against one Cache.GetItems call plus pipelined GetExtents over D-Bus, measured on GNOME 50; the second is 8 to 20 times faster and survives hung apps.
tags: [linux, at-spi, d-bus, spike, performance, wayland]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T23:30:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-25T23:30:00Z }
stale_after: 2027-04-25T00:00:00Z
sources:
  - id: atspi-xml
    resource: at-spi2-core's xml/Cache.xml and xml/Component.xml (2.60)
---

Measured on the owner's Ubuntu 26.04.1 desktop (GNOME 50 on Wayland,
at-spi2-core 2.60.4) on 2026-10-25, with two throwaway C programs.

# What was compared

- **libatspi walk**: for every node, `get_name`, `get_role`,
  `get_state_set`, `Component.get_extents` and the children, one D-Bus round
  trip each. This is what a straightforward port of the AX walk would do.
- **Cache plus pipelined extents**: one `org.a11y.atspi.Cache.GetItems` call
  on `/org/a11y/atspi/cache`, which returns every object of the app with its
  parent, index, child count, interfaces, name, role, description and states
  [^atspi-xml], then `Component.GetExtents` for every object sent at once
  over the same connection and collected as the replies arrive.

# Results

| App | Nodes | libatspi walk | GetItems | + all extents |
|---|---|---|---|---|
| Nautilus (GTK 4) | 225 | 49 ms | 2 to 6 ms | 4 ms |
| Ptyxis (GTK 4) | 146 | 29 ms | 1 to 5 ms | 2 ms |
| gjs app | 175 | 15 ms | 5 ms | not measured |
| GNOME Shell | 2,473 | 467 ms | 14 to 25 ms | 48 ms |
| rustdesk (hung) | 11 | 16,129 ms | 3 ms | not measured |

- Both read the same nodes; GetItems returns the whole tree, not only the
  visible part.
- A hung app stalls a walk for libatspi's default per-call timeout on every
  call. One GetItems call with a short timeout fails fast instead.
- Google Chrome showed 7 nodes: its web contents expose a tree only once
  accessibility is switched on for it, the Linux side of the
  [hidden trees](/design/chromium-and-canvas.md) work.

# Decisions it supports

- The AT-SPI backend talks D-Bus itself rather than through libatspi:
  GetItems for the tree, pipelined calls for frames and values, and short
  per-call timeouts.
- Round trips, not D-Bus, are the cost, so the client has to pipeline.

# Wayland coordinates

GTK 4 apps answer `GetExtents` in screen coordinates (`0`) with x and y of 0:
on Wayland an app doesn't know where its window is. Window coordinates (`1`)
are correct, for example Nautilus's sidebar at 1828,344 in its window. So
AT-SPI gives frames relative to the window; placing them on the screen needs
the window's position from the compositor, which is
[L5](/plan/linux.md)'s work. Element actions through AT-SPI don't need
coordinates.
