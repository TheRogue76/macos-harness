# Contributing to macos-harness

Thanks for helping. Bug reports, fixes, flows for more apps and documentation
are all welcome.

## Reporting a bug

Open an issue with the bug template. The most useful thing you can attach is the
file `macos-harness doctor --report` writes: the versions, permissions, pairing,
policy, recent errors and what the agent asked for lately, with no typed text,
screenshots or window titles (`--include-titles` keeps titles). If an agent did something odd, `macos-harness journal` lists its
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

`build-app.sh dev --install` builds `macOS Harness Dev.app` and `Harness Fixture.app`
into `~/Applications` and links the CLI as `~/.local/bin/macos-harness-dev`. The dev app
is separate from a released `macos-harness`, with its own permissions, pairings, socket
and journal, so both can be installed at once. Releases are built with
`scripts/release.sh` (Developer ID signing and notarization).

| Path | What |
|---|---|
| `Sources/HarnessProtocol` | JSON-RPC wire types, paths, the journal format and socket I/O shared by every process |
| `Sources/HarnessCore` | The helper's platform-neutral logic: tree shaping and search, policy, journal, pairing, activity, window claims, adb. Builds on macOS and Linux |
| `Sources/HarnessMac` | The helper's macOS side: accessibility, capture, input, windows, menus, apps, simulators, process inspection, the socket server. Builds on macOS only |
| `Sources/HarnessClient` | Finds, starts and talks to the helper; text rendering; the MCP server |
| `Sources/macos-harness` | The CLI |
| `Sources/MacosHarnessHelper` | The menu bar helper app |
| `Sources/HarnessFixture` | A small app with predictable state for the harness's own tests |
| `fixtures/ios` | The same for iOS: an Xcode project the iOS flows build and run on a simulator |
| `fixtures/android` | The same for Android: a plain-Java app `scripts/build-android-fixture.sh` builds without Gradle |
| `skills/macos-harness` | The agent skill `setup pi` installs |
| `packaging/` | The Homebrew cask template |
| `docs/` | The user guides; `docs/reference` is generated |
| `knowledge/` | Project knowledge in [Open Knowledge Format](knowledge/references/okf-spec.md); start at [knowledge/index.md](knowledge/index.md) |

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

## Documentation

The guides are in [`docs/`](docs/README.md). The CLI and MCP reference in
`docs/reference` is generated from `--help` and the tool schemas: after changing a
command, an option or a tool, run `python3 scripts/gen_reference.py`. CI fails when the
reference is out of date. Names agents and scripts rely on change only as the
[interface contract](knowledge/design/interface-contract.md) allows.

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
