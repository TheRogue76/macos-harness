# Unattended runs

Agents can use macOS Harness on a schedule, with nobody watching: a nightly job that reads
a web page into a spreadsheet, or a check that an app still works. This guide covers what
such a job needs and what it can't do.

## How it fits together

The scheduled agent (for example `claude -p` started by `launchd`) runs `macos-harness mcp`
or calls the `macos-harness` CLI. Both talk to the **macOS Harness** menu bar app over a
socket, and that app holds the Accessibility and Screen Recording permissions. The job
itself needs no permissions of its own. If the menu bar app isn't running, the first call
starts it.

## Run the job in your login session

Your apps and the menu bar app run in your login session, so the job has to run there too.
On macOS that means a **LaunchAgent** (a property list in `~/Library/LaunchAgents`, loaded
with `launchctl bootstrap gui/$(id -u) <plist>`), not a LaunchDaemon, which runs outside
any login session.

`launchd` starts jobs with a short `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that doesn't
include Homebrew, so call `macos-harness` by its full path (`/opt/homebrew/bin` on Apple
silicon, `/usr/local/bin` on Intel), or set `PATH` in the property list's
`EnvironmentVariables`. The same goes for your agent's own command.

## Approve the agent once, while you're there

The first time an agent acts, the menu bar asks you to allow it. A scheduled job has nobody
to answer, so the request is refused after 2 minutes (error 1001). Run the job once while
you're at the Mac and choose **Allow**, not **This session only**. Agents are recognized by
their code signature, so every later run of the same agent is covered. If you revoke it in
the panel's settings, it asks again.

## Keep the Mac awake and unlocked

While the Mac is locked, macOS shows no app windows and takes no input; `doctor` and
`launch` say so. Schedule the job for when the Mac is unlocked, and keep it from sleeping
while the job runs, for example by running the agent under `caffeinate -d -i`. `caffeinate`
can't unlock a Mac, and a display that sleeps may lock it, depending on your Lock Screen
settings.

## Where the job's windows should be

- **Reading** (`snapshot`, `find`, `screenshot`) works in windows that other windows cover.
  A browser's tree can also be read while its window is minimized or the app is hidden
  (⌘H); a minimized window's screenshot is blank.
- **Browsers pause minimized and hidden pages.** A scroll in a minimized Chrome window takes
  effect only once the window shows again, so a page that loads more as it scrolls stops
  loading.
- **Clicks and scrolls** go to the window in the background, without your cursor, when the
  window is on screen on the Space you're on; being covered is fine. Otherwise they need the
  real mouse (see below).
- **Windows on another Space (desktop) are out of reach**: macOS doesn't let accessibility
  see them, so the job gets an error saying the window is on another Space. Bringing the
  app forward
  (`launch "App" --activate`) switches your Space, which a job shouldn't do while you work.
- **Covered Chrome and Electron windows** are throttled, so their pages and trees can lag
  or stop updating, unless the app was started with
  `--disable-backgrounding-occluded-windows`. `launch` adds it when it starts the app; a
  browser you opened yourself doesn't have it.

## Give the job a browser of its own

For web pages, the most reliable setup is a browser instance that belongs to the job: it
starts on the Space you're on, keeps working when covered, and leaves your own browser
alone. Use a profile folder of its own, sign in to the sites it needs once by hand, and
have each run start it and quit it:

```bash
macos-harness launch "Google Chrome" --new-instance \
  --arg="--user-data-dir=$HOME/Library/Application Support/my-job-chrome" \
  --arg=--force-renderer-accessibility --arg=https://example.com --json
macos-harness quit <pid from launch>
```

## Reading long lists

`collect` reads a feed or list that shows only part of itself at a time: it scrolls by
bringing the last item into view, or with a background scroll, never your mouse, returns
each item once, and stops at a limit, a text such as a date (`--until`), the end of the
list, or after `--max-seconds`; `--continue` carries on from there. `--key /status/` tells
posts apart by their permalink, so a post whose like count changed isn't read twice.

## Staying out of your way

Accessibility actions and background clicks and scrolls don't move your cursor or change
the front app, so a job using them doesn't interrupt you. Some steps need the real mouse
and keyboard, such as drags, hovers, `--real`, and clicks the background route can't send
(text fields in some apps, sheets). These wait until
you've stopped using the mouse and keyboard, bring the app forward briefly, then give the
front back. A job that must never take them should avoid those steps.

`--no-diff` (`diff=false` over MCP) keeps clicks and scrolls in the background; it only
skips checking what changed.

## Stops

You can stop any agent from the menu bar or with ⌃⌥⌘. (the stop hotkey). Its calls then
fail with error 1004 until you resume it, and the stop survives restarts. A job should
treat 1004 as "stop now" and exit, not retry.

## Checking what a run did

Every request is in the journal: `macos-harness journal` lists sessions, and
`macos-harness journal last` shows the newest one's requests (typed text is never
recorded). `macos-harness doctor --report` writes a report to attach to a bug.
