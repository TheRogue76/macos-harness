# Design

* [Actions, safety rules and the MCP server](actions.md) - How agents act on apps in M2 (AX first, background keys second, never the cursor), how targets are chosen, what an action reports back, the focus and typing guards, and the MCP tools.
* [Helper UI: Control Tower](ui-control-tower.md) - The chosen menu bar design (direction B) in light and dark, what each surface shows, and the rules behind sessions, stopping, pairing and the on-screen overlay.
* [Snapshot format and pruning rules](snapshot-format.md) - What `snapshot`, `find` and `screenshot` show an agent, how the raw AX tree is pruned, how refs and coordinates work, and which notices exist.
* [Journal and policy](journal-and-policy.md) - The per-session JSON Lines journal of every agent request (typed text redacted) and the policy file that blocks apps or makes them read-only.
