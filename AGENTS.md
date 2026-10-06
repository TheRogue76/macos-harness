# macos-harness

A harness that lets coding agents (Claude Code, Codex, pi and others) see and
operate macOS apps: the Mac counterpart of Claude's iOS Simulator tool.

Status: milestones M0 (foundations), M1 (seeing), the Control Tower UI and M2
(acting through AX, plus the MCP server) are built. CLI: `doctor`, `apps`,
`windows`, `snapshot`, `find`, `screenshot`, `menu`, `press`, `set-value`, `type`,
`key`, `focus`, `select`, `scroll-to`, `increment`, `decrement`, `menu-select`,
`window`, `launch`, `quit`, `wait`, `mcp` (and hidden `spike`). Actions:
[actions design](knowledge/design/actions.md). Output conventions: [snapshot format](knowledge/design/snapshot-format.md); helper UI:
[Control Tower](knowledge/design/ui-control-tower.md). Plan and next milestones:
[`knowledge/plan/`](knowledge/plan/index.md).

## Working on the code

```bash
swift build && swift test                 # build and run unit tests
scripts/build-app.sh dev --install        # sign and install the dev helper + CLI
macos-harness doctor                      # check helper, permissions and pairing
scripts/acceptance-m1.sh                  # snapshot + screenshot every tier A app
scripts/acceptance-m2.sh                  # the four M2 tasks, no real input
```

- The CLI talks to the helper over a Unix socket in
  `~/Library/Application Support/macos-harness/`. If your sandbox blocks it
  (Codex's default one does), the CLI says so; allow that path or run outside
  the sandbox. See [agent hosts](knowledge/references/agent-hosts.md).
- The first gated command from a new agent shows a pairing prompt that the
  user must approve.

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
