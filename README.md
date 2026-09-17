# ops-toolkits

Small, dependency-light ops/SRE tools for running controlled changes against
production application hosts: capture a baseline, make the change, validate
against the baseline, gate a pipeline on the result, audit for drift
afterward. Mostly Bash, with a PowerShell counterpart where a Windows host
is the realistic target.

## [windchill-ops-toolkit](windchill-ops-toolkit/) — done, 16/16 tests

Pre-change and post-change health checks for Windchill-style application
hosts (Apache, Tomcat, JVM, disk, logs). Report-only by default; Nagios-style
exit codes so any monitoring agent can consume it directly.

## [deploy-validator](deploy-validator/) — done, 30/30 tests

Answers one question after a deployment: did it land correctly? Reads a
manifest (YAML or JSON) describing the expected state — files, version
strings, running services, HTTP endpoints — and checks it against the live
host. Read-only; built to gate a CI/CD pipeline step on its exit code.

## [db-healthcheck](db-healthcheck/) — done, 41/41 tests

Tablespace/session/lock/invalid-object/long-query health checks for a
relational database. Postgres and SQLite backends are real and tested
(a disposable Docker Postgres container with genuine lock/constraint
fixtures); the Oracle backend is written against its documented data
dictionary views but explicitly marked unverified — no instance available
to test against, and the README says so plainly rather than implying
otherwise.

## [upgrade-preflight](upgrade-preflight/) — done, 39/39 tests

Answers one question before a deployment or upgrade: is this host actually
ready? Disk space, backup freshness, current version, service state, stuck
zombie processes — checked against a manifest, ending in a GO/NO-GO
decision. Deliberately mirrors deploy-validator's design (manifest format,
exit-code shape) since the two are meant to be used as a before/after pair
around a change window.

## [webserver-config-audit](webserver-config-audit/) — done, 74/74 tests (38 Bash + 36 PowerShell)

Checks an Apache httpd.conf and/or Tomcat server.xml against a policy file,
flagging configuration drift (exposed `/server-status`, version-leaking
`ServerTokens`, weak TLS, a still-deployed Tomcat manager app, ...). Two
independent implementations of the same checks against the same policy
format — Bash and PowerShell — each with its own real test suite, because a
config-drift auditor is exactly the kind of tool that needs to run on
whichever OS the web server actually lives on.

## Common design decisions

- **Report-only / read-only by default.** None of these tools modify,
  delete, or restart anything unless explicitly told to (`--apply` in
  windchill-ops-toolkit; everything else never touches the system it
  checks at all).
- **No external test framework.** Every project's test suite is
  self-contained and runs against the real binary — real fixture files,
  a real disposable Docker container where a database is involved, a real
  backgrounded process for service checks, even a genuine zombie process
  for upgrade-preflight's stuck-process check. Nothing here asserts against
  a mock.
- **Bash 3.2+, tested on the actual bash macOS ships.** Every Bash suite
  runs against macOS's real `/bin/bash` (3.2, kept at that version for
  licensing reasons), not just Linux — which is how several real,
  otherwise-invisible bugs got caught (see each project's own README,
  "Bugs this caught").
- **Honest about what's unverified.** Where a check can't be confirmed
  (db-healthcheck's Oracle backend, a webserver-config-audit finding that
  needs a human to read old-style Apache access control, an
  upgrade-preflight webapps directory that can't be located), the tool
  says so — WARN or an explicit unverified label — rather than guessing
  PASS or FAIL.

## Requirements

Bash 3.2+ and standard coreutils across the board. Beyond that, per
project: `curl` and optionally `jq` (deploy-validator, upgrade-preflight);
`psql`/`sqlite3`/optionally `sqlplus` (db-healthcheck, plus Docker for its
Postgres integration tests); `xmllint` and, for the PowerShell
implementation, PowerShell 7+ (webserver-config-audit). See each project's
own README for full detail.
