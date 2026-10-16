---
type: Reference
title: When the cask can go into Homebrew's main repository
description: Homebrew accepts a cask its own author submits once the GitHub repository has at least 225 stars, 90 forks or 90 watchers and is at least 30 days old; on 16 October 2026 macos-harness had 4 stars and was 10 days old, so it stays in the owner's tap.
tags: [homebrew, release, distribution]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T09:00:00Z }
stale_after: 2027-04-16T00:00:00Z
sources:
  - id: policy
    resource: https://docs.brew.sh/Package-Acceptance-Policy
    title: Homebrew Package Acceptance Policy
    author: team:homebrew
  - id: casks
    resource: https://docs.brew.sh/Acceptable-Casks
    title: Homebrew Acceptable Casks
    author: team:homebrew
---

# The rule

A new cask has to show interest beyond its author. For a GitHub project
that normally means 30 forks, 30 watchers or 75 stars, and when the
repository's owner submits it, 90 forks, 90 watchers or 225 stars. A
repository less than 30 days old is normally not eligible.[^policy] These
are norms, not guarantees.[^casks]

# Where macos-harness stands

On 16 October 2026 the repository had 4 stars, no forks and no watchers,
and was created on 6 October 2026. Until it qualifies, the app ships
through `TheRogue76/homebrew-tap` (`macos-harness`, and `macos-harness@rc`
for pre-releases; see the [release process](/plan/release-process.md)).
When it qualifies, the cask from `packaging/macos-harness.rb` goes to
homebrew/cask, and the tap keeps working until that's accepted
([#36](https://github.com/TheRogue76/macos-harness/issues/36)).

[^policy]: Homebrew Package Acceptance Policy
[^casks]: Homebrew Acceptable Casks
