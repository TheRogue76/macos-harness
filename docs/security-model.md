# Staying in control

macOS Harness gives agents your Mac's apps. These are the controls you have over that,
and what they don't cover.

## Who can use it

- **Permissions stay with the helper.** Accessibility and Screen Recording are granted to
  the **macOS Harness** menu bar app, not to your terminal or your agents. Everything goes
  through it.
- **One approval per agent.** Each new agent asks once, in the menu bar. Agents are
  recognized by their code signature (name, signing team and identifier), found from the
  process that called; **Allow** covers every session of that agent, **This session only**
  just the one asking. Revoke an agent from the menu bar's gear menu.
- **Callers outside an agent**, such as a command you type in Terminal, are named after the
  terminal ("Terminal (typed by you)") and paired the same way.
- **CI's auto-approval** (`MACOS_HARNESS_AUTO_APPROVE=1`) only works when the helper is
  started as a child of the calling shell with `MACOS_HARNESS_LAUNCH=child`, where it has
  only the permissions that shell already had ([flows in CI](flows.md#in-ci)).

## Seeing what agents do

- **The menu bar panel** shows which agent is working in which app and what it did
  recently. A window an agent works in gets an orange outline that follows it; where it
  clicks, a ripple shows.
- **The journal** logs every request per session in
  `~/Library/Logs/macos-harness/journal` (gear menu › **Show Journal**, or
  `macos-harness journal`). Text agents type is never recorded, only its length. Sessions
  are kept for 30 days.

## Stopping agents

Pause one agent session from the panel, or stop them all with the big button or
**⌃⌥⌘.** from any app. Stopped agents stay stopped, even across restarts of the helper,
until you resume them from the panel; an agent that's told it was stopped should ask you.
A stopped session can't get around it by starting a new process.

## Real mouse and keyboard

Most actions go through accessibility or to a window in the background and leave your
cursor alone. When an agent needs the real mouse or keyboard:

- it waits until you've stopped typing and moving the mouse, and only one agent drives at
  a time;
- it stops if you move the mouse or type mid-gesture;
- your cursor is put back afterwards, and so is the app you had in front;
- it refuses to type while Secure Input is on (a password field has focus somewhere).

Several agents can work at once: a window, simulator or Android device a session acts in
stays its own for 30 s after its last step, and the others take turns with the mouse and
keyboard.

## The clipboard

`paste` borrows the clipboard: it keeps what you'd copied, puts the agent's text on it
(marked so clipboard managers skip it), pastes, and puts yours back, unless you copied
something meanwhile. `clipboard` lets an agent read what's on it, but never text a password
manager marked as concealed, and the journal records only that it was read. macOS asks you
the first time macOS Harness reads the clipboard; `doctor` shows whether it may.

## The policy file

Block apps, or make them read-only, in `~/.config/macos-harness/policy.yaml` (gear menu ›
**Edit Policy…**):

```yaml
blocked:
  - com.apple.Passwords
read_only:
  - Mail
  - Messages
```

Agents can't see blocked apps at all (they're missing from `apps` and `windows`), and can
read but not act on read-only ones. A flow can add its own policy for the length of its
run.

## What this doesn't protect against

- **It's not a security boundary.** The guard rails protect you from agents' mistakes, not
  from software determined to get around them: anything running as you can edit the
  policy file, and an agent with a shell can do whatever your user can.
- **What agents read, they can send on.** Screenshots and trees of your apps go into the
  agent's context, and from there to its model provider. Block or close apps with data
  you don't want read.
- **System dialogs are yours.** The harness reports a system dialog in front (a permission
  prompt, a password request) and doesn't answer it for you; agents are told not to.

## Private interfaces and the network

macOS Harness makes no network connections. Background clicks and scrolls use private
macOS functions (SkyLight's event posting); if a future macOS removes them, those actions
fall back to the real mouse and nothing else changes.

Found a vulnerability? Report it privately as [SECURITY.md](../SECURITY.md) describes.
