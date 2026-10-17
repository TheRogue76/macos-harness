# macOS Harness guides

- [Getting started](getting-started.md): install, permissions, connecting your agent,
  pairing, and a first look at what agents can do.
- [Flows](flows.md): repeatable UI checks in YAML, turning an agent's session into one,
  and running them in CI.
- [iOS Simulators](ios-simulators.md) and [Android](android.md): driving simulators,
  emulators and phones with the same commands.
- [Unattended runs](unattended.md): running agents on a schedule (launchd), approving them
  once, keeping the Mac unlocked, and where their windows should be.
- [Staying in control](security-model.md): pairing, stopping agents, the policy file, the
  journal, and what the guard rails don't protect against.
- [Troubleshooting](troubleshooting.md): permissions, pairing, stops, Device Hub and other
  common problems.
- [Known limitations](limitations.md): what doesn't work, or works only partly.
- Reference, generated from the code: [CLI](reference/cli.md) and [MCP tools](reference/mcp.md).
  What stays stable across versions is in the
  [interface contract](../knowledge/design/interface-contract.md).

Design notes, research and the roadmap are in [knowledge/](../knowledge/index.md).
