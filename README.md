# ops-toolkits

Small, dependency-light Bash tools for running controlled changes against
production application hosts: capture a baseline, make the change, validate
against the baseline, gate a pipeline on the result.

## [windchill-ops-toolkit](windchill-ops-toolkit/)

Pre-change and post-change health checks for Windchill-style application
hosts (Apache, Tomcat, JVM, disk, logs). Report-only by default; Nagios-style
exit codes so any monitoring agent can consume it directly.

## [deploy-validator](deploy-validator/)

Answers one question after a deployment: did it land correctly? Reads a
manifest (YAML or JSON) describing the expected state — files, version
strings, running services, HTTP endpoints — and checks it against the live
host. Read-only; built to gate a CI/CD pipeline step on its exit code.

## Common design decisions

- **Report-only / read-only by default.** Neither tool modifies, deletes, or
  restarts anything unless explicitly told to (`--apply` in
  windchill-ops-toolkit; deploy-validator never touches the system at all).
- **No external framework.** Each project's `tests/run-tests.sh` is
  self-contained and runs against the real binary, not mocks.
- **Bash 3.2+.** Both suites are tested against macOS's shipped `/bin/bash`
  (3.2, kept at that version for licensing reasons) as well as Linux, so
  nothing here silently breaks on a Mac.

## Requirements

Bash 3.2+, standard coreutils, `curl`. `jq` only if you use JSON manifests
with deploy-validator. See each project's own README for full detail.
