# Flows

A flow is a YAML file of steps with expectations, for UI checks you want to repeat:

```yaml
name: Calculator multiplies
app: Calculator
setup:
  - launch: Calculator
steps:
  - press: { id: One }
  - press: { id: Two }
  - press: { id: Multiply }
  - press: { id: Three }
  - press: { id: Four }
  - press: { id: Equals }
  - expect: { role: text, text: "408" }
teardown:
  - quit: { app: Calculator, if_launched: true }
```

Steps are the commands agents use (`press`, `type`, `key`, `click`, `drag`, `menu`,
`wait`, `collect`, `sim`, `android`, `build`…) plus `expect` checks, `shell` commands, variables
(`${name}`, set with `--var name=value`), `only_if` guards, and a policy that applies only
while the flow runs. The full format is in
[flows](../knowledge/design/flows.md).

## Running

```bash
macos-harness flow check flows/                 # parse and validate without running
macos-harness flow run flows/                   # run every flow in the folder
macos-harness flow run calc.yaml --var n=12 --junit report.xml --record failures
```

Setup runs first, then the steps until one fails, then teardown always. A failure saves a
screenshot, the UI tree and the step log under `--artifacts` (and, with `--record
failures`, a movie of the run); `--junit` writes a report CI systems read. The exit code
is 1 when any flow fails.

Teardown steps that delete or close things should say what they're allowed to touch,
with an `only_if` guard naming what the flow created, so a flow never closes or deletes
something of yours.

## From an agent's session

```bash
macos-harness flow export last --name "Sign in" --out sign-in.yaml
```

turns the latest journal session into a flow (printed, or saved with `--out`): what the
agent did, step by step. Text it typed becomes `${text_1}`, `${text_2}`… variables to fill
in, since the journal never records typed text. `macos-harness journal` lists the
sessions.

The `steps` command (MCP: `steps`) runs flow steps from an agent in one call, so a
sequence an agent got right can be pasted into a flow unchanged.

## In CI

GitHub's macOS runners grant Accessibility and Screen Recording to the job's shell, so
the helper can run as a child of it and use them. Two environment variables opt in:
`MACOS_HARNESS_LAUNCH=child` starts the helper that way, and
`MACOS_HARNESS_AUTO_APPROVE=1` approves every caller, since no one is there to answer the
pairing prompt. Both are needed, and they grant nothing the job's shell didn't already
have.

This repository's own [UI flows workflow](../.github/workflows/ui.yml) is a working
example: it builds and installs the app, runs `flow check`, runs the flows with `--record
failures --junit`, and uploads the results. Hide the Dock on runners, whose screens are
small. Flows that need a real user's apps or data belong on your own Mac, not in CI.

## Recording

`record start -a App [--out file.mov] [--max-seconds 600]` records only that app's windows
(menus and popovers included, nothing else), with the cursor; `record stop` finishes the
file; `record frames file.mov --every 1` saves stills from it.
