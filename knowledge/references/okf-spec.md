---
type: Reference
title: Open Knowledge Format (OKF) v0.2
description: The format this knowledge bundle follows, and the rules that matter here.
resource: https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md
tags: [okf, format, knowledge]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
sources:
  - id: spec
    resource: https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md
    title: OKF specification v0.2
    author: team:google-cloud
    last_modified: 2026-08-21T20:08:36Z
---

# What it is

An open format from Google Cloud for knowledge that people and agents share:
a folder of markdown files with YAML frontmatter, one concept per file, linked
with ordinary markdown links. No runtime, SDK or registry.[^spec]

The canonical repo is `GoogleCloudPlatform/open-knowledge-format`. The copy
under `GoogleCloudPlatform/knowledge-catalog/okf` is a frozen snapshot; don't
follow it.

# Rules that matter here

- Every `.md` file except `index.md` and `log.md` is a concept and needs
  frontmatter with a non-empty `type`. That is the only hard requirement.
- `index.md` lists a folder's contents for progressive disclosure. It has no
  frontmatter, except the bundle root may declare `okf_version`.
- `log.md` holds `## YYYY-MM-DD` sections, newest first.
- Trust: `generated: { by, at }` records who wrote a concept; `verified`
  records who confirmed it. Tiers: unverified, machine-confirmed (non-human
  verifiers only), human-reviewed (any `human:` verifier).
- Lifecycle: `status` (`draft` | `stable` | `deprecated`, default `stable`)
  and `stale_after` (an absolute instant).
- Provenance: `sources` entries with `resource` (URL, bundle path or a scope
  descriptor) and an `id` for footnote attribution.
- Actors: `<producer>/<version>`, `human:<id>`, `process:<id>`.
- Consumers must tolerate unknown types and keys, broken links and missing
  indexes.

# Not used yet

`Attested Computation` (a sanctioned computation plus executor and attester)
is part of v0.2 but has no use in this project so far.

[^spec]: OKF specification v0.2
