---
type: Reference
title: Agent hosts and how they call tools
description: How Claude Code, Codex and pi can call an external tool (MCP, CLI, skills) and view screenshots.
tags: [agents, mcp, cli, interface, claude-code, codex, pi]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
stale_after: 2027-01-06T00:00:00Z
sources:
  - id: m0-codex
    resource: "`codex sandbox macos` runs of the harness CLI, Codex 0.131.0, 2026-10-06"
    title: M0 Codex sandbox tests
    author: claude-code/claude-opus-5-5
  - id: codex-permissions
    resource: https://learn.chatgpt.com/codex/permissions
    title: Codex permission profiles
    author: team:openai
  - id: pi-ronacher
    resource: https://lucumr.pocoo.org/2026/1/31/pi/
    title: Armin Ronacher on pi
    author: human:mitsuhiko
  - id: pi-packages
    resource: https://pi.dev/packages?name=mcp
    title: pi package catalog (MCP adapters)
---

# Integration surfaces

| Host | MCP | Shell CLI | Instructions file | Viewing a screenshot |
|---|---|---|---|---|
| Claude Code | Yes (stdio, HTTP) | Yes | `CLAUDE.md`, skills | Image content in tool results; `Read` on a PNG path |
| Codex | Yes (configured servers) | Yes | `AGENTS.md` | Image viewing tool on a file path |
| pi | Not built in, by design; community adapter extensions exist[^pi-packages] | Yes, the preferred way[^pi-ronacher] | `AGENTS.md`, skills | Reads image files |

# Implication

The common denominator is a CLI that prints compact text or JSON and writes
screenshots to files. An MCP server can wrap the same core for hosts that
prefer native tool calls, and a skill or README teaches agents how to use it.
The owner chose exactly this ([requirements](/project/requirements.md)).

# Agent sandboxes and the helper socket

The CLI talks to the helper over a Unix socket in
`~/Library/Application Support/macos-harness/`. Agent sandboxes can block it.

| Host | Default | What works |
|---|---|---|
| Claude Code (desktop app) | Reaches the socket | Nothing needed |
| Codex 0.131 | Read-only sandbox blocks `connect()` with EPERM, confirmed in a full `codex exec` session[^m0-codex] | `--allow-unix-socket <harness dir>` (one-off), or `sandbox_mode = "workspace-write"` with `sandbox_workspace_write.network_access = true` (opens all networking) |
| pi 1.0.4 | No sandbox | Nothing needed; confirmed in a real `pi -p` session (chain `macos-harness ← node ← zsh ← login ← Terminal`) |

Codex's permission profiles have a narrower option
(`[permissions.<name>.network.unix_sockets]` with `"<socket path>" = "allow"`,
plus `network.enabled` and `features.network_proxy`).[^codex-permissions] A
profile extending `:workspace` or `:read-only` refused to run the harness
binary from `~/Applications` without logging a denial. Unresolved; revisit
for the M4 setup docs.

An MCP server sidesteps all of this: Codex and Claude Code start MCP servers
outside the command sandbox. That makes MCP the recommended route for
sandboxed agents, and the CLI the route for pi and unsandboxed use.

# Connecting agents

`macos-harness setup claude|codex|pi` does this (M4): it shows the change,
asks (or takes `--yes`), and uses each host's own tool so their config
formats stay theirs. `macos-harness setup` alone shows what's connected.

- **Claude Code:** `claude mcp add --scope user macos-harness -- <cli> mcp`.
  User-scope servers live under `mcpServers` in `~/.claude.json`.
- **Codex:** `codex mcp add macos-harness -- <cli> mcp`, which writes
  `[mcp_servers.macos-harness]` to `~/.codex/config.toml`;
  `codex mcp get <name> --json` reads it back.
- **pi:** the skill (`skills/macos-harness/SKILL.md`, shipped in the app's
  Resources) goes to `~/.pi/agent/skills/macos-harness/`. pi implements the
  Agent Skills spec and also reads `~/.agents/skills/`. Since M4, pi also has
  MCP of its own (`pi mcp add`, `~/.pi/agent/mcp.json`), so the MCP route
  would work too; the skill stays the plan for the CLI route.

`<cli>` is the path the CLI was started by, without resolving symlinks, so a
Homebrew upgrade doesn't break it (`/opt/homebrew/bin/macos-harness`; the dev
build is `~/.local/bin/macos-harness-dev`).

Each host pairs once, under its own identity, the first time a tool runs.

Pairing identities seen so far: `Claude Code|Q6L2SF6YDW|com.anthropic.claude-code`,
`Codex|2DC432GLL2|codex` and `pi|HX7739G8FX|node`. All are signing-based and
survive updates. An unanswered pairing prompt is refused after 2 minutes;
Codex gives up on MCP tool calls sooner by default.

pi sets `process.title = "pi"`. On macOS that overwrites the process's whole
argument list, so the only trace of pi is a `node` process whose argv[0] is
`pi`. The first version of the classifier missed this and labeled pi's calls
"Terminal (typed by you)"; it now checks argv[0] as well.

[^m0-codex]: M0 Codex sandbox tests
[^codex-permissions]: Codex permission profiles
[^pi-ronacher]: Armin Ronacher on pi
[^pi-packages]: pi package catalog (MCP adapters)
