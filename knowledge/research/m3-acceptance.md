---
type: Analysis
title: M3 acceptance run
description: Every M3 task passes with real input and guard rails (Chess drag, Finder file move, right-click menus, Notes, Reminders and Calendar test areas, stop hotkey); the run exposed a latched ⌘ modifier that made typing vanish, idle counters that count our own events, the Dock's invisible window, uncommitted text fields and noisy context menus, each now handled.
tags: [m3, acceptance, findings, real-input, safety, tier-b]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:15:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:10:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: run
    resource: "scripts/acceptance-m3.sh and manual CLI runs on macOS 27.2, 2026-10-06"
    title: M3 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

`scripts/acceptance-m3.sh` (13 checks, all passing) covers the fixture,
Finder and the stop hotkey. Chess and the tier B apps were run by hand with
the CLI.[^run]

| Task | How | Check |
|---|---|---|
| Click, drag, hover, right-click, scroll, real typing (fixture) | `click`, `drag --to-id`, `hover`, `click --right` then `press` the item's ref, `scroll --down`, `focus` + `type --real`, `key cmd+a --real` + `type --real` | click lands at the element's center (y 35 of 70); "Dropped: token"; "Hovering: yes"; "Chosen: done"; row 1 scrolls out; the field holds only the retyped text |
| Move a file between sandbox folders (Finder) | list view, `drag --text move-me.txt --to-text done` | the file is in `done/` and gone from where it was |
| Right-click menus (Finder) | `click --right` on a folder | items as refs, without separators or ⌥ alternates; Escape closes it |
| A move in Chess by dragging | AX press e2 → e4 (background), then a real drag g1 → f3 from screenshot coordinates | "white knight, f3" |
| Notes test area | File › New Folder on "On My Mac", right-click › Rename Folder, File › New Note, `type --real`, `type` (AX) to edit, right-click › Delete, right-click › Delete Folder | folder and note come and go; the user's 11 notes untouched |
| Reminders test area | Add List sheet (`set-value` + OK), Add Reminder + `type --real`, edit (focus, `set-value`, Tab), right-click › Delete on the reminder and the list | list and reminder come and go |
| Calendar test area | File › New Calendar › On My Mac, rename (`set-value` + Return), File › New Event (lands in the selected test calendar), retitle with real ⌘A + typing + Return, right-click › Delete, delete the calendar (Delete, not Merge) | calendar and event come and go |
| Stop hotkey halts a task | a 4 s drag in the background, ⌃⌥⌘. posted 1.5 s in | "The user stopped this agent partway through the action." |

All three apps hold only local accounts on this Mac, so nothing synced.
First-run prompts were dismissed without changing settings: Notes'
"What's New" and "Turn On iCloud" (Cancel), Reminders' welcome and "Enable
iCloud Syncing?" (Not Now), Calendar's splash. Notes keeps deleted notes in
Recently Deleted for 30 days; the run left them there rather than delete
them permanently.

# Findings, and what changed because of them

1. **⌘ stayed latched system-wide, and typing silently did nothing.**
   macOS reported left ⌘ as held for 40+ minutes with no key down. Events
   built from the system's event state inherit it, so every typed character
   arrived as ⌘-something (mostly ⌘A). The likely cause is the harness
   posting combos as one key event with the ⌘ flag, without ⌘'s own key
   events; a lost key-up can't be ruled out. Now modifiers are pressed and
   released as key events around the key or click, typed text never
   carries flags, and a session first releases modifiers macOS reports as
   held while the user is idle (`modifiers` notice). Scripts outside the
   helper couldn't post the fix: without the helper's permission, posted
   events are silently dropped.
2. **macOS counts our own events as user activity.** Synthetic HID events
   reset `secondsSinceLastEventType`, so "is the user idle?" said no right
   after our own clicks. The helper remembers when it last posted and only
   counts newer input as the user's.
3. **The Dock covers the screen with a transparent window.** Checking the
   window list under a point found the Dock (layer 20) everywhere and
   refused every click. AX's hit test (`AXUIElementCopyElementAtPosition`)
   ignores click-through windows; the window list is only a fallback.
4. **A text field written by AX can look changed while the app never
   hears of it.** In Reminders, `set-value` on a title updated the field but
   not the row label, and the change was lost. Focusing first starts an
   editing session, and Tab then saved it. `set-value` now focuses text
   fields first and adds an `editing` notice. Calendar's event popover
   ignored background Tab entirely; real typing with Return worked.
5. **⌘A ends inline renames.** In Notes' folder rename, ⌘A ended editing
   and the typed name went nowhere (the folder stayed "New Folder"). Rename
   fields select their text on entry, so typing alone works.
6. **Context menus are noisy and late.** AX lists separators (untitled,
   disabled items) and the ⌥ alternates stacked under items (same frame).
   Both are now dropped. Finder hangs its context menu off the window, so
   the diff already had it and items appeared twice until de-duplicated.
   Menu commands run after the fade-out, so Notes' Delete Folder looked
   like it did nothing until settling waited for the menu to close.
7. **Two sessions fought over the cursor.** A `key --real` call during a
   drag restored the cursor mid-drag, which the drag read as "the user
   moved the mouse". Real input now holds an exclusive lease, and keyboard
   sessions never touch the cursor.
8. **The stop check has to come first.** With ⌃⌥⌘. pressed during a drag,
   the panel opened and the drag stopped with "stopped being frontmost". A
   stop is now checked before cursor and frontmost checks, and the hotkey
   shows the panel without activating it.
9. **Restarting the helper cleared stops.** During the run, the helper was
   restarted to clear a test stop, which any agent with a shell could do
   too. Stops are now saved and survive restarts; the MCP instructions tell
   agents never to restart the helper around a stop.
10. **Detached background commands lost their identity.** A CLI call whose
    parent shell had exited showed as "Unknown process" and waited on
    pairing. Identification now falls back to the macOS "responsible
    process" chain, and pairing requests from processes that died are
    withdrawn.
11. **Chess's board reports mirrored AX geometry**, since it's drawn with
    OpenGL: square frames are flipped vertically, so element-based drags
    land on the wrong rank. AX presses or screenshot coordinates work. A
    short-lived extra window appears during piece drags and shows up as an
    "Opened window" notice.
12. **SwiftUI apps launched in the background may not open a window.** The
    fixture needs `launch --activate` (or `open`).
13. **Full snapshots and screenshots of tier B apps show personal data.**
    One full Notes screenshot showed the user's note titles. Use `find` for
    specific elements and `screenshot --element` to crop to the test area.
14. **No clipboard to restore.** The roadmap listed clipboard restore, but
    typing goes through AX or key events and never through the clipboard.
    It becomes relevant only if a paste path is added.

[^run]: M3 acceptance output
