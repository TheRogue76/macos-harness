# Contributing to macos-harness

Thanks for helping. Bug reports, fixes, flows for more apps and documentation
are all welcome.

## Reporting a bug

Open an issue with the bug template. The most useful thing you can attach is the
output of `macos-harness doctor`: it shows the versions, permissions, pairing and
policy in one go. If an agent did something odd, `macos-harness journal` lists its
sessions and `macos-harness journal <session>` what it asked for (typed text is
never recorded). Check screenshots and journal entries for personal data before
you attach them.

Security problems go through [SECURITY.md](SECURITY.md) instead, not public issues.

## Building

You need macOS 15 or later, Xcode 16 or later, and an Apple Development signing
identity (a free Apple account is enough).

```bash
swift build && swift test              # build and run the unit tests
scripts/build-app.sh dev --install     # install the dev app; its CLI is macos-harness-dev
macos-harness-dev doctor               # grant its permissions and check it
```

The dev app (`macOS Harness Dev`) is separate from a released `macos-harness`, with
its own permissions, pairings, socket and journal, so both can be installed at once.

## Testing

- `swift test` runs the unit tests; every change should keep them passing and add
  tests for new logic.
- `macos-harness-dev flow run flows/fixture flows/apps` runs what CI runs, against
  the bundled Harness Fixture app and Calculator.
- `scripts/acceptance-m*.sh` are each milestone's acceptance runs.
  `acceptance-m3.sh` moves your cursor and ends by pressing the stop hotkey; resume
  from the menu bar panel afterwards.
- iOS: test on a simulator you create (`xcrun simctl create "macos-harness tests"
  "iPhone 18 Pro"`) and delete it afterwards. Android: an emulator you create.

When you test against real apps, use places with no personal data: a test folder
in Notes, a test list in Reminders, a test calendar, a sandbox folder in Finder.
Flows that delete or close things must only touch what they created.

## Code style

- **No comments in code**, except a doc comment (`///`) on a declaration saying
  what it is or does. If code needs explaining, rename or restructure it; the
  reasons behind non-obvious code (platform quirks, workarounds) go in
  [`knowledge/`](knowledge/index.md).
- Swift 6, strict concurrency. Match the surrounding code's naming and idioms.
- User-facing text (errors, notices, help) is plain, specific and says what to
  do next.

## Project knowledge

[`knowledge/`](knowledge/index.md) holds the design notes, research and plan as
an [Open Knowledge Format](knowledge/references/okf-spec.md) bundle: one concept
per markdown file with frontmatter. When you learn something the next person would
otherwise have to rediscover (a decision, an API gotcha, a platform quirk), add or
update a concept, update its folder's `index.md`, add an entry to
`knowledge/log.md`, and run `python3 scripts/okf_lint.py`.

## Pull requests

- One change per pull request, with tests and any knowledge updates.
- Describe what changed and how you checked it (unit tests, flows, which apps).
- CI runs the unit tests and the UI flows on GitHub's macOS runners.

By contributing you agree that your work is released under the [MIT License](LICENSE).
