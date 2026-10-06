---
type: Project Brief
title: macos-harness goal
description: Give any coding agent the ability to see and operate macOS apps, matching what Claude has for the iOS Simulator.
tags: [goal, scope]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
sources:
  - id: kickoff
    resource: Claude Code session with human:parsa.nasirimehr on 2026-10-06
    title: Kickoff conversation
    author: human:parsa.nasirimehr
---

# Goal

Build the pieces that let agents work with Mac apps the way Claude's
[iOS Simulator tool](/references/claude-ios-simulator-tool.md) lets it work
with iOS apps: see the UI, read its structure, act on it and check the
result.[^kickoff]

# Requirements stated so far

- Callable by any agent, not only Claude: Claude Code, Codex, pi and
  others.[^kickoff] See [agent hosts](/references/agent-hosts.md) for how
  each one can call tools.
- It doesn't have to be an app, but an app is fine if the macOS permission
  model calls for one.[^kickoff] See [macOS permissions](/research/macos-permissions.md).
- Close the gaps listed in the [macOS gap analysis](/research/macos-gap-analysis.md).

# Scope and plan

The [requirements](/project/requirements.md) record the answers on scope,
safety, interface and distribution. The [architecture](/plan/architecture.md)
and [roadmap](/plan/roadmap.md) turn them into a build plan.

[^kickoff]: Kickoff conversation
