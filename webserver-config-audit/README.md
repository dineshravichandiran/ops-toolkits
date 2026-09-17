# webserver-config-audit

Checks an Apache `httpd.conf` and/or a Tomcat `server.xml` against a
policy file, flagging configuration drift. Read-only — never modifies
the configs it audits.

Two implementations of the same tool: `bin/webserver-config-audit`
(Bash) and `bin/webserver-config-audit.ps1` (PowerShell), sharing the
same `conf/policy.yaml` format and example configs, checked by two
independent test suites (`tests/run-tests.sh`, `tests/run-tests.ps1`)
against the same scenarios.

## Why config-drift auditing matters operationally

Nobody plans to leave `/server-status` open to the world or the default
Tomcat manager app deployed in production. It happens because someone
made a manual change during an incident — turned on directory listing to
debug a missing-file report, disabled a `Require` line to unblock a
health check that was failing for an unrelated reason — and the change
never got reverted once the incident was over. A config file doesn't
flag its own drift; the only way anyone finds out is either an audit or
an attacker. This tool is the former: a policy is a checked-in, versioned
statement of what "correct" looks like, and running it regularly (or as
a CI/CD gate before a config change is deployed) turns "we assume this
is still locked down" into an actual, repeatable answer.

## Three-state output, not binary pass/fail

Unlike `deploy-validator` and `upgrade-preflight` (binary PASS/FAIL —
they gate a pipeline, and a pipeline needs a yes/no), this tool reports
**PASS / WARN / FAIL**. A config audit is read by a person, and
collapsing "I couldn't confirm this one way or the other" into either a
false-clean PASS or an alarming FAIL would throw away real information.
WARN is used for:

- Old-style Apache 2.2 `Order`/`Allow`/`Deny` access control on
  `/server-status` or `/server-info` — recognized as "something is
  restricting this," but its merge rules aren't evaluated, so it's
  flagged for a human to actually read rather than confidently graded.
- No `<Directory>` block found at all for a path that's supposed to have
  directory listing disabled — genuinely unknown, not confirmed safe.
- A Tomcat webapps directory that can't be located (see below) — cannot
  verify the default-apps check at all, so it says so instead of
  guessing PASS.
- An SSL connector with no explicit `protocols` attribute — Tomcat has a
  real default here, but confirming it's still within policy needs a
  human to check the actual Tomcat version installed.

Exit codes: `0` PASS, `1` WARN present (no FAIL), `2` FAIL present, `3`
usage/internal error.

## Policy format

One `policy.yaml`, checked by both implementations:

```yaml
apache:
  server_tokens: Prod
  server_signature: Off
  timeout_max_seconds: 60
  restrict_server_status: true
  restrict_server_info: true
  directory_listing_disabled:
    - /var/www/html

tomcat:
  connector:
    port: 8080
    protocol: "HTTP/1.1"
    min_max_threads: 150
    max_connection_timeout_ms: 20000
  default_apps_must_be_absent:
    - manager
    - host-manager
  ssl:
    min_protocol: TLSv1.2
```

See `conf/example-httpd.conf` and `conf/example-server.xml` for complete,
fully policy-compliant generic examples. Nothing in any file here refers
to a real company, product, or hostname.

## Usage

```bash
# Bash
./bin/webserver-config-audit --policy conf/policy.yaml --httpd-conf /etc/httpd/conf/httpd.conf
./bin/webserver-config-audit --policy conf/policy.yaml --server-xml /opt/tomcat/conf/server.xml --json
```

```powershell
# PowerShell
./bin/webserver-config-audit.ps1 -Policy conf/policy.yaml -HttpdConf /etc/httpd/conf/httpd.conf
./bin/webserver-config-audit.ps1 -Policy conf/policy.yaml -ServerXml /opt/tomcat/conf/server.xml -Json
```

The Tomcat default-apps check looks for `webapps/manager` and
`webapps/host-manager` next to `conf/server.xml` by default (the
standard `$CATALINA_BASE` layout); pass `--webapps-dir`/`-WebappsDir`
explicitly if your layout differs.

## What differs between the two implementations, and why

Both check the same things, but they aren't line-for-line translations —
each uses the tool actually idiomatic to its language, and the
differences are real, not cosmetic:

- **XML parsing.** The Bash version shells out to `xmllint --xpath`
  (ships with macOS, standard on most Linux distros). PowerShell has a
  native `[xml]` type and `SelectSingleNode`/XPath support built in, so
  the PowerShell version needs no external tool at all for the Tomcat
  checks.
- **Case sensitivity.** PowerShell's `-match`/`-ieq` are case-insensitive
  by default (`.NET` regex), so `Test-ServerTokens` matches `ServerTokens`
  regardless of case. The Bash version is limited to matching directives
  in their canonical Apache case — not a design preference, but a real
  constraint: macOS's `/usr/bin/awk` (the classic "one true awk") has no
  `IGNORECASE` (a gawk-only extension), and virtually every real
  `httpd.conf` is written in canonical case anyway.
- **JSON output.** The Bash version builds its JSON by hand with
  `printf`. PowerShell has `ConvertTo-Json` built in, so the PowerShell
  version's JSON path is considerably shorter — at the cost of its own
  sharp edge (see "Bugs this caught," below).

## Tests

```bash
./tests/run-tests.sh      # 38 assertions
./tests/run-tests.ps1     # 36 assertions
```

Both build real fixtures — copies of the example configs with exactly
one deviation each — and run the real binary against them, no mocking.
Both cover: a fully-compliant baseline, each Apache check failing on its
own (`ServerTokens`, `ServerSignature`, `Timeout`, unrestricted
`server-status`, enabled directory listing, old-style access control as
WARN), each Tomcat check failing on its own (`maxThreads`,
`connectionTimeout`, wrong protocol, weak SSL protocol, missing
connector, a deployed default app, an unlocatable webapps directory as
WARN), usage errors, and `--json`/`-Json` output.

## Bugs this caught during development

This project surfaced more real, platform-specific bugs per line of code
than anything else in this toolkit — worth going through, because every
one of them looked correct on a read-through and only broke when
actually run.

**`awk`'s `close` is a reserved builtin, not just a convenient variable
name.** The Apache block-extraction helper originally used a variable
named `close` to hold the tag's closing-line pattern. `close()` is an
awk builtin function (closes a file/pipe); BWK awk (macOS's
`/usr/bin/awk`) rejects a variable that shadows a builtin with a flat
syntax error, while gawk is more permissive about it. Renamed to
`closetag`.

**XML forbids a literal `--` inside a comment, and my own example file
had one.** `example-server.xml`'s header comment originally read "...no
real hostnames or company names -- adjust before use...", and `xmllint`
refused to parse the file at all: `Double hyphen within comment`. This
is in the XML spec, not an `xmllint` quirk — any real XML parser would
reject it.

**BSD `sed` has no `0,/regex/{...}` address form.** The test fixtures
originally used GNU sed's idiom for "replace only the first match in the
whole file" to build single-deviation Tomcat fixtures. macOS's `sed`
doesn't support that address form at all and fails with a generic `bad
flag in substitute command` error. Replaced with a small `perl -pe`
one-liner (`perl` ships on macOS and Linux alike) using brace delimiters
so the literal `/` in strings like `protocol="HTTP/1.1"` needs no
escaping.

**A `[string[]]` parameter marked `[Parameter(Mandatory)]` breaks
argument binding, but only when the array came from `Get-Content` and
the script runs via `pwsh -File`.** Every helper in the PowerShell
version that takes the config's lines as an array threw `Cannot bind
argument to parameter 'Lines' because it is an empty string` — despite
the array being neither empty nor a string. It did not reproduce via
`pwsh -Command`, and did not reproduce with a literal array assigned
directly (`@("a","b","c")`) via either invocation mode. Isolating it took
working down from the real failure to an 8-line repro, one variable at a
time (hashtable-literal context? not it. Function name? not it. Named vs.
positional parameters? not it. Finally: the `Mandatory` attribute on the
array parameter itself, only under `-File`). Fixed by not marking
array-typed parameters `Mandatory` — the function's own logic never
actually depended on that attribute doing the validation.

**`Write-Host` cannot be redirected, silenced, or piped away — at all.**
The PowerShell version's `-Json` mode printed valid-looking JSON, but
piping it to a JSON parser failed. The cause: every `Write-Finding`/
`Write-Section` call during the check run had already written its
human-readable line straight to the host UI stream via `Write-Host`,
which — unlike Bash's stdout — has no connection to the normal
success-output stream at all, so nothing downstream (`> $null`, a pipe,
`Out-Null`) can suppress it. The fix isn't a redirect; it's a
`$script:JsonMode` flag that these functions check and skip `Write-Host`
entirely when set.

**A test harness parameter literally named `$Args` silently shadows
PowerShell's automatic `$args` variable.** (Variable names are
case-insensitive.) `Invoke-Audit`'s helper function took `param($Args)`
and splatted it back with `@Args` — which meant every single invocation
during test development actually passed nothing through to the real
`pwsh -File` call. Since the target script's `-Policy` parameter is
`Mandatory`, PowerShell's response to a missing Mandatory parameter is
to *interactively prompt for it* — and because the child process's stdin
wasn't an interactive terminal, every test invocation hung indefinitely
waiting for input that could never arrive, rather than failing fast.
Renamed the parameter to `$AuditArgs`.

**A relative `-ServerXml` path silently breaks the webapps-directory
default.** Deriving the default webapps location as
`<server.xml's dir>/../webapps` via two `Split-Path -Parent` calls works
for an absolute path, but for a shallow relative path like
`conf/server.xml`, the second `Split-Path -Parent` returns an empty
string (a relative path only has as many parent segments as it was
given), and `Join-Path` then fails outright on an empty `Path`. Fixed by
resolving to an absolute path with `Resolve-Path` first.

## Scope and limitations

Neither implementation is a general Apache-config or XML parser. The
Apache reader understands top-level directives and single-level
`<Location>`/`<Directory>` blocks, matched by canonical case in the Bash
version (see above); it does not re-implement Apache's actual
Options-merging rules (`+`/`-` prefixes merging with the parent context
vs. a bare value replacing it entirely) — it checks the matched block's
own `Options` line only. The Tomcat default-apps check is
directory-presence-based (`$CATALINA_BASE/webapps/manager` existing or
not), which is what actually determines whether the webapp is deployed,
rather than anything declared in `server.xml` itself. Both are
intentional simplifications for the scope of what this tool checks, not
oversights — where the simplification matters, the check reports WARN
rather than guessing.
