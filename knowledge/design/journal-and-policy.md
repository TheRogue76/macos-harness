---
type: Design
title: Journal and policy
description: The per-session JSON Lines journal of every agent request (typed text redacted) and the policy file that blocks apps or makes them read-only.
tags: [design, m4, journal, policy, privacy, safety]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T21:20:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M4 decisions
---

# Policy

`~/.config/macos-harness/policy.yaml`, shared by the dev and release
builds. It ships absent, which means no restrictions.[^roadmap]

```yaml
blocked:          # agents can't see or touch these
  - com.apple.Passwords
read_only:        # snapshot, find, screenshot, menu and wait work; actions don't
  - Mail
  - Messages
```

- Entries are app names or bundle IDs, case-insensitive. An app in both
  lists is blocked.
- **Blocked** apps refuse every request that names them (including
  `launch`) and disappear from `apps` and `windows`.
- **Read-only** apps refuse `act`, `pointer`, `menu-select`, `window` and
  `quit`; `launch` is allowed so an agent can open an app to read it.
- Refusals use error code 1005 and say which rule applied.
- The helper re-reads the file when it changes. A file it can't use
  (invalid YAML, a list that isn't a list, an unknown key such as
  `readonly`) refuses every agent request until it's fixed. A typo must
  never silently open an app. `doctor` shows the file's state and fails.
- The menu bar's gear menu has **Edit Policy…**, which creates the file
  from a commented template and opens it.

The policy guards against agents' mistakes, not against software that's
determined to get around it: anything running as the user can edit the file.

# Journal

Every request the helper handles for an agent, except `hello`, `doctor`
and spikes, is one JSON line in
`~/Library/Logs/macos-harness/journal/<session>.jsonl` (`journal-dev` for
the dev build). A session is one agent's run of requests; two minutes of
quiet starts a new one. Session IDs look like `20261006-231902-claude-code`.

Each entry records the time, agent, method, app and window, the action,
how the agent named the element (ref or selector) and what it resolved to
(ref, role, label, identifier), how the action ran (`AX`, `background
keys`, `real input`), the number of changes, notice kinds, any error and
the duration.

**Typed and set text is never written**, only its length
(`redactedLength`), per the owner's decision.[^roadmap] Neither are
change details or the `performed` text, which can quote it. Key
combinations, menu paths and search text are kept.

Files are readable only by the user (folder 0700, files 0600). Sessions
older than 30 days are deleted when the helper starts.

`macos-harness journal` lists sessions; `macos-harness journal <id>` (or
`last`) shows one; both take `--json`. **Show Journal** in the gear menu
opens the folder. M5's `flow export` builds on these files.

[^roadmap]: Roadmap, M4 decisions
