---
type: Design
title: Building and running your own Mac app
description: How `build` chooses between the iOS Simulator and this Mac (natively or as Mac Catalyst) from `xcodebuild -showdestinations`, finds the app, and with `--run` quits the running copy and launches the new build; the CLI, MCP and flow forms, and the native Mac fixture.
tags: [design, build, xcodebuild, macos, catalyst, flows, fixtures]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-15T19:45:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-15T20:20:00Z }
stale_after: 2027-10-15T00:00:00Z
sources:
  - id: issue
    resource: https://github.com/TheRogue76/macos-harness/issues/21
    title: "Build and run your own Mac app (#21)"
  - id: ios
    resource: /design/ios-simulator.md
    title: iOS Simulator targets, the `build` command
---

# What it does

`build --run` on a Mac app's scheme builds it with `xcodebuild`, quits the
copy of the app that's running, launches the new build the way `launch`
does and returns its pid and windows, so "change code, build, look at it,
act on it" is one command.[^issue] Everything happens in the client; the
helper is only asked to list apps, quit and launch, as for any agent. The
simulator side is unchanged ([iOS Simulator targets](/design/ios-simulator.md)).[^ios]

# Choosing the platform

`build` asks `xcodebuild -showdestinations` which destinations the scheme
has, unless `--device` names a simulator (then it builds for that one, as
before):

| Scheme's destinations | Default | `--mac` |
|---|---|---|
| iOS Simulator, and macOS or Mac Catalyst | the iOS Simulator | this Mac |
| macOS or Mac Catalyst, no iOS Simulator | this Mac | this Mac |
| iOS Simulator only (or "Designed for iPad" on the Mac) | the iOS Simulator | error naming the platforms |
| none it can run (watchOS, visionOS…) | error naming the platforms | error |
| unreadable (the call failed) | the iOS Simulator, as before | macOS |

"This Mac" is native macOS when the scheme lists a macOS destination
without a variant, and Mac Catalyst when it lists only `variant:Mac
Catalyst`. A scheme whose iOS platform isn't installed lists its iOS
Simulator destination as ineligible, so it builds for the Mac. `--mac` with
`--device` is a usage error.

Why not `-showBuildSettings`: without a destination xcodebuild resolves the
settings against a default destination of its own. For the iOS fixture
(Catalyst on) that is My Mac (Mac Catalyst), so `SDKROOT` is `macosx` and
`SUPPORTED_PLATFORMS` gains `macosx`; overriding `SUPPORTS_MACCATALYST=NO`
on the command line still listed `macosx` (Xcode 27.1). The destination
list is what Xcode's run destination menu offers, which is the question.
It's text, not JSON: lines like `{ platform:macOS, arch:arm64,
variant:Mac Catalyst, id:…, name:My Mac }` under a header. Sections whose
header says incompatible (Xcode 27: "Destinations incompatible with") or
ineligible (Xcode 16: "Ineligible destinations for") are skipped, and so
is any entry with an `error:` field. It takes under a second.

The build's destination is `platform=macOS,arch=<arch>` (plus
`variant=Mac Catalyst`), with the architecture of the first matching
destination in the list. `platform=macOS` alone also matches the Rosetta
x86_64 "My Mac", and xcodebuild warns that it used the first of several;
`generic/platform=macOS` would build every architecture in `ARCHS`, since
a generic destination has no active one.

# Finding the app

As for simulators: `-showBuildSettings -json` with the build's own
destination gives `TARGET_BUILD_DIR`/`FULL_PRODUCT_NAME` (`Debug/` for
macOS, `Debug-maccatalyst/` for Catalyst) and `PRODUCT_BUNDLE_IDENTIFIER`.
The outcome says which platform it built for: `build.platform` is
`ios-simulator`, `macos` or `mac-catalyst`.

# Running it

1. The helper's `apps` (background apps included) gives every running app
   with the build's bundle ID, compared without case. Each is asked to
   quit by pid (`quit`, not forced, 10 s). One that doesn't quit, usually
   because it's asking to save, stops the run with a message naming its
   pid; unsaved work is never thrown away. Nothing else is quit: the match
   is the exact bundle ID, not the name. A running SwiftUI app brings
   XPC services listed under its name, such as `AutoFill (Harness Fixture
   Mac)` (`com.apple.SafariPlatformSupport.Helper`) and
   `ThemeWidgetControlViewService (Harness Fixture Mac)`, which a name
   match could catch.
2. The helper's `launch` opens the `.app` by path, in the background
   (like `launch` without `--activate`), and waits up to 15 s for the first
   window.

The older copy goes because it's the stale build: left running, it would
share the new build's name and bundle ID, so `-a Name` and bundle ID
targets couldn't tell them apart, and `launch` by name or bundle ID returns
the running copy. Launching by path needs no helper change.

`--json` keeps `{build, launch}` (`launch` is the simulator's result) and
adds `macLaunch` (the `launch` result: `app.pid`, `windows`,
`milliseconds`) and `replaced` (the copies quit first). Text output adds
"Quit the running copy of … (pid …)" lines before the launch.

# MCP and flows

The MCP `build` tool takes `mac` and, as before, returns a build ID at
once. The background job plans first, so `run=true` on a scheme that
builds for the simulator without `device` fails in `build_status` before
compiling anything. With `run=true` on the Mac, `build_status` ends with
the quit lines and the launch: pid and windows.

Flows:

```yaml
app: mac-fixture
setup:
  - build: { project: ../../fixtures/mac/HarnessFixtureMac.xcodeproj, launch: true, as: mac-fixture }
teardown:
  - quit: { app: mac-fixture, if_launched: true }
```

`mac: true` forces the Mac. `as` names the launched copy, mapped to its pid
like `launch … as:`, and counts as launched by the flow for `if_launched`.
`install` means nothing on the Mac; `mac` with `device`, and `as` without
`launch`, are errors, and `as` on a build that went to the simulator fails
the step.

# The fixture

`fixtures/mac/HarnessFixtureMac.xcodeproj` is a native SwiftUI Mac app
(a counter, a text field, a greeting, all with identifiers), chosen over
building the iOS fixture for Catalyst: Catalyst is already covered by
`flows/catalyst`, and the native path (no variant, `Debug/`, `SDKROOT
macosx`) is how most Mac apps are made and was exercised nowhere. The
project file is written by hand like the iOS one: one target and a
synchronized folder. It signs ad hoc (`CODE_SIGN_IDENTITY = "-"`), so it
builds without a team on any Mac or runner, and targets macOS 15 like the
harness.

`flows/mac/fixture.yaml` builds it (the platform detected), presses
Increment twice, builds again with `mac: true` and checks that the count is
back to 0 in the new copy. It needs only Xcode and the fixture, nothing of
the owner's, so CI runs it in the `flows` job.

Measured on the owner's Mac (macOS 27.2, Xcode 27.1, 15 October 2026): an
up-to-date `build --run` takes 4–8 s, of which the build is about 1 s and
the launch 0.3–3.4 s; the flow passes in 7.6 s. The first build of the
fixture took 15 s.

[^issue]: Build and run your own Mac app (#21)
[^ios]: iOS Simulator targets, the `build` command
