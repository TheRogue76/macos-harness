# macos-harness

A harness that lets coding agents (Claude Code, Codex, pi and others) see and
operate macOS apps: the Mac counterpart of Claude's iOS Simulator tool.

Status: milestones M0 (foundations), M1 (seeing), the Control Tower UI, M2
(acting through AX, plus the MCP server), M3 (real input with guard rails) and
M4 (first public release, 0.1.0 via Homebrew) are built. CLI: `doctor`, `apps`,
`windows`, `snapshot`, `find`, `screenshot`, `menu`, `press`, `set-value`,
`type`, `key`, `focus`, `select`, `scroll-to`, `increment`, `decrement`,
`click`, `hover`, `drag`, `scroll`, `menu-select`, `window`, `launch`, `quit`,
`wait`, `journal`, `setup`, `mcp` (and hidden `spike`). Releases:
[release process](knowledge/plan/release-process.md); policy and journal:
[design](knowledge/design/journal-and-policy.md). Actions:
[actions design](knowledge/design/actions.md). Output conventions: [snapshot format](knowledge/design/snapshot-format.md); helper UI:
[Control Tower](knowledge/design/ui-control-tower.md). Plan and next milestones:
[`knowledge/plan/`](knowledge/plan/index.md).

## Working on the code

```bash
swift build && swift test                 # build and run unit tests
scripts/build-app.sh dev --install        # install the dev helper; CLI: macos-harness-dev
macos-harness-dev doctor                  # check helper, permissions and pairing
scripts/acceptance-m1.sh                  # snapshot + screenshot every tier A app
scripts/acceptance-m2.sh                  # the four M2 tasks, no real input
scripts/acceptance-m3.sh                  # real input: fixture, Finder, stop hotkey
scripts/release.sh [--publish]            # notarized release; see the release process
```

- `acceptance-m3.sh` moves the user's cursor and ends by stopping every
  agent (the stop hotkey check); the user resumes from the menu bar panel.
  Don't restart the helper to clear a stop: stops are saved, and restarting
  around one is exactly what the guard rail forbids.
- Testing on the owner's Mac: Notes, Reminders and Calendar only inside a
  `macos-harness tests` folder, list or calendar you create and remove;
  Finder only in `~/macos-harness-sandbox`; Mail, Messages and FaceTime read
  only. Prefer `find` and `screenshot --element` over full snapshots of those
  apps, which show personal data. See
  [test targets](knowledge/plan/test-targets.md).
- The CLI talks to the helper over a Unix socket in
  `~/Library/Application Support/macos-harness/`. If your sandbox blocks it
  (Codex's default one does), the CLI says so; allow that path or run outside
  the sandbox. See [agent hosts](knowledge/references/agent-hosts.md).
- The first gated command from a new agent shows a pairing prompt that the
  user must approve.

## Comments

- No comments in code. The one exception is a doc comment on a declaration
  (`///` in Swift, a docstring in Python, KDoc in Kotlin) saying what the
  function, type or property does or is, never how it works inside.
- So no inline or trailing comments, `// MARK:` lines or commented-out code.
  If code needs explaining, rename or restructure it.
- Reasons behind non-obvious code (platform quirks, workarounds, ordering
  that matters) go in `knowledge/`, not in the code.
- A script's header saying what it does and how to run it counts as its doc
  comment. Toolchain directives (`// swift-tools-version`, shebangs) aren't
  comments.

## Project knowledge (OKF)

Durable project knowledge lives in [`knowledge/`](knowledge/index.md), an
[Open Knowledge Format v0.2](knowledge/references/okf-spec.md) bundle: a folder
of markdown files with YAML frontmatter, one concept per file.

- Start at `knowledge/index.md` and open only what the task needs.
- Treat `status: draft` or unverified concepts as leads, not settled facts.
- Check `stale_after` before relying on facts about machine state or versions.

### When to write

Write or update a concept when you learn something a future agent would
otherwise have to rediscover: a decision and its reasons, a platform
constraint, an API gotcha, a measured fact about the environment.

Don't write what the code or git history already records, or notes that only
matter to the current task.

### How to write

- One concept per file, kebab-case name, in the folder that fits. Make a new
  folder (with an `index.md`) when nothing fits.
- Frontmatter: `type` (required), `title`, `description` (one sentence, reused
  in `index.md`), `tags`, `status` (`draft` | `stable` | `deprecated`), and
  `generated: { by: <actor>, at: <UTC ISO 8601> }`.
- Actors: agents write `<agent>/<model>` (for example
  `claude-code/claude-opus-5-5`, `codex/<model>`, `pi/<model>`); people write
  `human:<id>`. The owner is `human:parsa.nasirimehr`. Only a person adds a
  `human:` entry to `verified`; an agent that re-checks a fact against the
  machine adds itself.
- Facts with a shelf life (machine state, OS or tool versions) get a
  `stale_after` instant.
- Cite external material under `sources` with an `id`, and attribute specific
  claims with footnotes `[^id]`.
- Link concepts with bundle-relative links: `[permissions](/research/macos-permissions.md)`.
- Never delete superseded knowledge: set `status: deprecated` and link to its
  replacement.
- After any change: update the folder's `index.md`, add an entry to
  `knowledge/log.md` (newest date first), then run:

```bash
python3 scripts/okf_lint.py
```

Concept types in use: `Project Brief`, `Requirements`, `Architecture`,
`Plan`, `Test Plan`, `Design`, `Analysis`, `Platform Constraint`, `Reference`,
`Environment`. Add new types when none fit, such as `Decision` for choices
made during the build. Spike results go in `research/` as `Analysis`.
