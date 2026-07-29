# Security policy

## Supported versions

The latest release and `main` receive fixes. There are no long-term support
branches.

## Reporting a vulnerability

Report privately through GitHub's
[security advisory form](https://github.com/dimmmmmmmer/takeshot/security/advisories/new)
rather than a public issue. Include what you found, how to reproduce it, and
what an attacker gains. Expect a first response within a week.

## Scope notes

TakeShot is a local desktop application: it captures video, writes files to a
folder you choose, and talks to Blackmagic hardware. It has no network
services, no telemetry and no accounts.

What is in scope:

- Code execution or privilege escalation through crafted media, LUT (`.cube`)
  or CSV files the app parses.
- Writing outside the destination and offload folders the operator selected
  (path traversal through file names read from disk).
- Content injected into exports (CSV, EDL) that executes when a production
  opens them in another application — spreadsheet formula injection was fixed
  in this class and regressions count as vulnerabilities.

What is not in scope: the Blackmagic SDKs and their runtimes (report those to
Blackmagic Design), and anything requiring the attacker to already have the
operator's local account.
