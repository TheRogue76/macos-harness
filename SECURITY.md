# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub: on the
repository's **Security** tab, choose **Report a vulnerability**. Include what an
attacker could do, the steps to reproduce, and the versions involved
(`macos-harness doctor` prints them).

The maintainer replies as soon as they can. Fixes for confirmed problems ship in a
patch release, and the advisory credits you unless you'd rather it didn't.

## What's in scope

macOS Harness holds Screen Recording and Accessibility permissions and acts on
your Mac for coding agents, so these matter most:

- a process getting the helper to act, read or capture **without pairing**, or
  past a stop, the policy file or a window another session holds;
- the helper or CLI doing something its caller didn't ask for, or more than the
  pairing and policy allow;
- personal data leaving your Mac, or being written somewhere it shouldn't be
  (the journal never records typed text; screenshots are deleted as documented);
- the socket, files or preferences the helper creates being readable or
  writable by other users;
- anything in the release build, its signing or its Homebrew cask.

## What isn't

Pairing, the policy file and the stop hotkey protect you from agents' mistakes.
They aren't a security boundary against software that is already running as you:
such a process can edit the policy file, read the journal, or post input events
itself. Reports that need the attacker to already run code as your user, with
nothing more gained, are out of scope. So is the private macOS API the background
clicks use breaking on a new macOS version; that's a bug, not a vulnerability.
