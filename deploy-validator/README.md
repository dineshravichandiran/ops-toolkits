# deploy-validator

Answers one question after a deployment or upgrade: **did it land correctly?**

Reads a manifest describing what a correct deployment looks like — files
that should exist, version strings that should appear somewhere, services
that should be running, HTTP endpoints that should respond a certain way —
and checks every item against the live host. Read-only. Nothing here ever
writes, deletes, restarts, or otherwise touches the system it's checking.

## Why manifest-driven

The alternative to a manifest is a script with the expected state baked
into `if` statements — which means every application, every environment,
and every release needs its own copy of the checking logic edited by hand.
That's how validation scripts rot: nobody wants to touch a script when the
only thing that changed is a version number, so the script stops matching
reality and eventually stops getting run at all.

A manifest separates "what does correct look like" (data, owned by whoever
knows the application and changes every release) from "how do we check
that" (code, owned by the tool and shouldn't need to change per release).
The same binary validates any application; only the manifest changes. That
also makes the manifest itself useful as a release artifact — it's a
checked-in, versioned statement of what a given release is supposed to look
like once deployed, which is worth having independent of whether the tool
that reads it ever runs.

## Why exit codes matter

This tool exists to be a gate, not a report. A CI/CD pipeline step, a
deployment runbook, an Ansible `command` task, a cron job that pages
someone — none of them read prose. They read an exit code.

- `0` — every item in the manifest passed. Safe to proceed / close the
  change window / mark the pipeline stage green.
- `1` — at least one item failed. The pipeline stage should fail, the
  runbook should stop, someone should look before calling the deployment
  done.
- `2` — the tool itself was misused or the manifest couldn't be read
  (bad path, malformed file). This is not "the deployment is broken," it's
  "the check couldn't run," and pipelines usually want to treat that
  differently (e.g. retry, or alert on the pipeline rather than the
  deployment).
- `3` — internal error (a required library or command is missing). Same
  idea as `2`: the problem is the tool's environment, not the deployment.

Keeping "deployment is broken" (`1`) distinct from "the check couldn't run"
(`2`/`3`) matters in practice — a pipeline that treats them the same will
eventually roll back a perfectly good deployment because the validator
itself hit a transient problem, or worse, wave through a broken one because
a misconfigured manifest path silently produced an exit code the pipeline
read as "fine."

## How this fits into a deploy pipeline

```
deploy application
  |
  v
deploy-validator --manifest release-3.4.0.yaml --strict
  |
  +-- exit 0 --> pipeline continues / change window closes
  |
  +-- exit 1 --> pipeline fails the stage, deployment is rolled back
  |              or handed to a human, per the pipeline's own policy
  |
  +-- exit 2/3 -> pipeline treats this as its own infrastructure problem,
                  not a verdict on the deployment
```

The manifest for a release is typically checked into the same repository
as the release or generated as part of the build, so "what does this
release look like when deployed correctly" travels with the release
itself rather than living only in one engineer's head.

### `--strict` vs default mode

Default mode checks every item and reports every failure together — useful
when a human is going to read the output and wants the full picture in one
pass rather than fixing one thing, re-running, hitting the next failure,
and repeating.

`--strict` stops at the first failure. Useful as a pipeline gate where the
pipeline just needs a fast yes/no and every second the deployment sits in
an unknown state is a second someone is staring at a spinner.

Both modes use the same exit code convention, so a pipeline can switch
between them without changing how it interprets the result.

## Manifest format

YAML or JSON, auto-detected by extension (`.yaml`/`.yml` or `.json`; other
extensions are sniffed by looking for a leading `{`). Four sections, all
optional — a manifest with only `services:` and nothing else is valid:

```yaml
# Files that must exist. "version" is optional; when present, deploy-validator
# greps the file for that string.
files:
  - path: /opt/app/webapps/app.war
    version: "3.4.0"
  - path: /opt/app/conf/server.xml

# Version strings to grep for in files that aren't otherwise covered by
# files: above -- e.g. a version stamped inside a larger config file, or a
# build manifest unpacked from the archive.
version_checks:
  - path: /opt/app/webapps/app/META-INF/MANIFEST.MF
    pattern: "Implementation-Version: 3.4.0"

# Services that must be running (systemd checked first, falls back to a
# process-table match so this also works on hosts without systemd).
services:
  - httpd
  - tomcat

# HTTP endpoints that must return a specific status code.
endpoints:
  - url: "http://localhost:8080/app/health"
    expected_status: 200
```

See `conf/example-manifest.yaml` and `conf/example-manifest.json` for
complete, runnable examples against a generic Tomcat-behind-Apache Java web
application. Nothing in either example refers to a real company, product,
or hostname — adjust every path and version before use.

JSON manifests are parsed with `jq`; if `jq` isn't installed, JSON manifests
will fail with a clear error and YAML manifests still work (the YAML parser
has no external dependency). YAML manifests are parsed with a small
purpose-built line reader, not a general YAML library — it understands
exactly the shape shown above (a flat list of `key: value` mappings under
four known section headers) and nothing more exotic.

## Usage

```bash
# Check everything, see every failure
./bin/deploy-validator --manifest release-3.4.0.yaml

# Gate a CI/CD pipeline step: stop at the first problem
./bin/deploy-validator --manifest release-3.4.0.yaml --strict

# Machine-readable output for a pipeline to parse instead of grepping text
./bin/deploy-validator --manifest release-3.4.0.yaml --json
```

### Example output

```
deploy-validator  |  manifest: release-3.4.0.yaml  |  2026-09-17 14:22:03

Files
[PASS] file:/opt/app/webapps/app.war present
[PASS] file:/opt/app/conf/server.xml present

Versions
[PASS] version:/opt/app/webapps/app.war found expected string '3.4.0'

Services
[PASS] service:httpd                active (systemd)
[FAIL] service:tomcat                inactive (systemd)

HTTP endpoints
[PASS] http:http://localhost:8080/app/health HTTP 200 as expected

Summary
  items checked : 4
  pass          : 3
  fail          : 1

Failures
  - service:tomcat: inactive (systemd)

OVERALL: FAIL
```

## Tests

```bash
./tests/run-tests.sh
```

30 assertions, run against the real `bin/deploy-validator` binary — not
mocked. The suite builds real fixture files, starts a real background
process with a unique marker so the service check has something genuine to
find, and starts a real local HTTP server so the endpoint check gets a real
response. It covers:

- a fully-passing manifest (every check type, one manifest)
- a manifest with a missing file
- a manifest with a wrong version string
- a manifest with a service not running
- a manifest with a bad HTTP response
- multiple simultaneous failures, reported together in default mode
- `--strict` stopping at the first failure
- `--json` output being well-formed and matching the text-mode counts
- a JSON-format manifest (not just YAML) being accepted
- usage errors (missing manifest file, missing `--manifest` argument)

All fixtures are cleaned up on exit via a trap, including the background
service process and the HTTP server, whether the suite passes or fails.

## Requirements

Bash 3.2+, standard coreutils, `curl` for endpoint checks. `jq` is required
only if you use JSON manifests — YAML manifests need nothing beyond Bash
itself. Tested on Linux and on macOS's shipped `/bin/bash` (3.2).

## Two bugs this caught during development, worth knowing about

**`pgrep -f` self-matching.** The first version of the service check used
`pgrep -f "$svc"` directly. On a host where the *invocation* of
deploy-validator itself contains the service name in its command line
(e.g. a wrapper script, a CI job whose argv includes the manifest path or
service name), `pgrep -f` matches its own process and reports a service as
running when it isn't. Fixed by excluding the current PID and its parent
from the match. This is the kind of bug that passes every manual test run
from a terminal and only shows up inside automation — which is exactly
where a deployment validator spends its life, so it mattered here.

**JSON output silently reporting zero for everything.** The `--json` code
path originally ran the checks via command substitution
(`out="$(run_all_checks)"`), which bash executes in a subshell. The check
functions update shell variables (`ITEMS_TOTAL`, `ITEMS_FAIL`, etc.) as
side effects; those updates never left the subshell, so every JSON summary
reported `0` regardless of what actually happened. Fixed by running the
checks directly in the current shell and discarding only the human-readable
text output, not the process itself. Caught by the test suite's assertion
on `items_total` in the `--json` scenario — which is the argument for
asserting on actual values rather than just exit codes.

**`curl`'s `-w '%{http_code}'` double-counted on connection failure.** On a
refused or timed-out connection, `curl -s -o /dev/null -w '%{http_code}'`
writes `000` to stdout via `-w` *and* exits non-zero. The original code was
`code=$(curl ... || echo "000")`, which assumed curl's own output was
empty on failure — but it isn't, so the command substitution captured
curl's `000` and then the `||` fallback appended a second `000` on top,
producing the literal string `000000` and breaking the "no response or
timeout" branch entirely (`000000` matches neither `000` nor any real
status code, so it fell through to a garbled "HTTP 000000, expected 200").
Fixed by capturing curl's output unconditionally and only falling back to
`000` when the captured string is actually empty. Covered by a dedicated
regression test against a port nothing is listening on.

**Empty-array iteration under bash 3.2's `set -u`.** `check_versions`
iterates two arrays (`MANIFEST_FILE_VERSIONS`, `MANIFEST_VERSION_CHECKS`),
either of which can be empty depending on the manifest. Bash 4.4+ expands
`"${empty_array[@]}"` to zero words under `set -u`; bash 3.2 — what macOS
ships as `/bin/bash`, for licensing reasons — treats it as an unbound
variable and aborts. The obvious fallback, `"${empty_array[@]:-}"`, isn't a
reliable fix either: inside a function, bash 3.2 expands that to a single
*empty-string* element rather than zero, which silently ran a version check
against a blank path and reported a bogus failure. The fix that actually
holds across both bash versions and both scopes is a length guard before
the loop: `if (( ${#arr[@]} )); then for x in "${arr[@]}"; do ...`. Caught
by running the real test suite on real macOS bash, not by inspection —
both broken variants pass a superficial read.

## Scope and limitations

This checks the host and application layer visible to the OS: files,
process/service state, and HTTP responses. It doesn't understand
application-internal state (a service that's "running" but stuck, a web
app that returns 200 with an error page, a database migration that's
half-applied). It's a first-pass sanity check meant to catch the common,
mechanical ways a deployment fails to land — not a substitute for
application-specific smoke tests.
