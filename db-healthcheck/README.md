# db-healthcheck

Tablespace usage, active sessions, blocked/waiting sessions, invalid
objects, and long-running queries — the same shape of "is this database
about to cause an incident" check regardless of which database engine is
underneath.

## Oracle vs. what was actually tested

This tool's design target is Oracle, but **I don't have an Oracle instance
available to develop or test against.** Being upfront about exactly what
that means for each piece:

| Piece | Status |
|---|---|
| `lib/backend-postgres.sh` | **Proven.** Exercised by `tests/run-tests.sh` against a real, disposable Postgres container — every scenario (an unvalidated constraint, a session genuinely holding a lock, a second session genuinely blocked on it, a genuinely long-running query) is real database state, not a mock. |
| `lib/backend-sqlite.sh` | **Proven**, for what it covers. Real local SQLite files, real `PRAGMA integrity_check` / `PRAGMA foreign_key_check` results. It deliberately does *not* attempt sessions/locks/long-running-queries — see below. |
| `lib/backend-oracle.sh` | **Unverified.** Written against Oracle's documented data dictionary views (`DBA_TABLESPACES`, `V$SESSION`, `V$LOCK` via `BLOCKING_SESSION`, `DBA_OBJECTS`), using the same `report()`/`classify()` contract as every other backend, connecting via `sqlplus` the same way the Postgres backend connects via `psql`. It has never been run against a real Oracle instance. Treat it as a concrete, reviewable draft of what the real implementation would look like, not as tested code. |
| `bin/db-healthcheck`, `lib/common.sh` | **Proven** — backend-agnostic, exercised through both the Postgres and SQLite paths. |

If I get access to a real Oracle instance, the plan is: point
`backend-oracle.sh` at it, run the same category of fixtures (an invalid
object, a real blocking session, a real long-running query) against it,
and fix whatever the first real run inevitably finds — exactly what
happened developing the Postgres backend (see "Bugs this caught," below).

## Why Postgres stands in for Oracle, and where the analogy breaks

Both are full client/server RDBMSes with real sessions, real locks, and a
real catalog — which is exactly what SQLite doesn't have, and why SQLite
alone wouldn't be a credible stand-in. But the analogy isn't perfect, and
rather than paper over the gaps, each check documents its own adaptation
in `lib/backend-postgres.sh`:

- **Tablespaces.** Oracle tablespaces are datafile-backed with a genuine
  maximum size, so "percent used" is a first-class number
  (`DBA_TABLESPACES` / `DBA_DATA_FILES`). Postgres tablespaces are just
  directories with no intrinsic size limit — there is no honest
  percentage to compute. This backend reports each tablespace's actual
  size in MB and classifies it against an operator-configured absolute
  threshold (`TABLESPACE_WARN_MB` / `TABLESPACE_CRIT_MB`) instead of
  inventing a fake percent-of-nothing.
- **Invalid objects.** Oracle's `DBA_OBJECTS.STATUS = 'INVALID'` covers
  any object left broken, usually by a failed DDL change. Postgres has no
  single equivalent status, but an index left half-built
  (`pg_index.indisvalid = false`, typically from a killed `CREATE INDEX
  CONCURRENTLY`) and a constraint added `NOT VALID` and never validated
  (`pg_constraint.convalidated = false`) are the same *category* of
  problem — an object that exists but can't be trusted — so this backend
  counts both.
- **Active sessions, blocked sessions, long-running queries.** These map
  cleanly: `pg_stat_activity` plays the same role as `V$SESSION`, and
  `wait_event_type = 'Lock'` is a direct analog of a session with a
  non-null `BLOCKING_SESSION`.

SQLite has none of the session/lock machinery at all — it's a
single-writer embedded file, not a server — so `backend-sqlite.sh` doesn't
pretend otherwise. `active_sessions`, `blocked_sessions`, and
`long_running_queries` are printed as explicit "not applicable" skips, not
run at all. What SQLite *does* have a genuine equivalent for —
`PRAGMA integrity_check` and `PRAGMA foreign_key_check` as a real
"invalid objects" signal, and the file's own size as a stand-in for
tablespace growth — is implemented and tested for real. The SQLite backend
exists as a zero-dependency way to exercise the tool's plumbing (config
loading, threshold classification, `--json`, exit codes) without Docker or
a network database, not as an Oracle substitute.

## Design decisions

**Nagios-convention exit codes**, matching the rest of this toolkit: `0`
OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN, worst status wins.

**Credentials never come from a CLI argument** (`ps` shows every process's
full argv to anyone on the box). They come from `DB_HEALTHCHECK_PASSWORD`,
or from a file path in `DB_HEALTHCHECK_PASSWORD_FILE` (for
Docker/Kubernetes-style secret mounts), or from a gitignored
`conf/db-healthcheck.conf`. Missing both is a hard failure (exit `3`,
UNKNOWN) — this tool never falls back to a guessable default password.

**One query, one check, one `report()` call**, identically shaped across
all three backends (`backend_check_tablespaces`, `backend_check_active_sessions`,
etc.), so a reviewer — or a future me adding a fourth backend — can
diff any two backends' implementation of the same check side by side.

## Usage

```bash
cp conf/db-healthcheck.conf.example conf/db-healthcheck.conf
# edit conf/db-healthcheck.conf: host, port, database, user, thresholds
export DB_HEALTHCHECK_PASSWORD='...'   # or DB_HEALTHCHECK_PASSWORD_FILE

./bin/db-healthcheck                        # postgres backend (default)
./bin/db-healthcheck --backend sqlite       # no server needed
./bin/db-healthcheck --json                 # machine-readable output
```

### Example output

```
db-healthcheck  |  backend: postgres  |  2026-09-17 22:10:03

Connectivity

Tablespaces
[OK      ] tablespace:pg_default        312MB (warn >=1024MB, crit >=5120MB)

Sessions
[OK      ] db:active_sessions           3 active session(s) (warn >=50, crit >=100)
[WARNING ] db:blocked_sessions          1 session(s) waiting on a lock (warn >=1, crit >=5)

Object validity
[OK      ] db:invalid_objects           0 invalid object(s): 0 index(es), 0 constraint(s) (warn >=1, crit >=5)

Long-running queries
[CRITICAL] db:long_running_queries      3 query(ies) running longer than 300s (warn >=1, crit >=3)

Summary
  checks run : 5
  ok         : 3
  warning    : 1
  critical   : 1
  finished   : 2026-09-17 22:10:03
```

## Tests

```bash
./tests/run-tests.sh
```

41 assertions. The first block is pure-bash unit tests (threshold
classification, credential resolution) with no database involved. The
second exercises the SQLite backend against real local files, including a
real dangling foreign key inserted with enforcement off so `PRAGMA
foreign_key_check` has something genuine to catch. The third spins up a
disposable `postgres:16-alpine` Docker container, seeds it with real
fixtures — a `NOT VALID` constraint, a session that actually holds an
`ACCESS EXCLUSIVE` lock via `pg_sleep`, a second session that actually
blocks trying to acquire it — runs the real binary against the real
container, and tears it down in a trap on exit whether the suite passes
or fails. If Docker isn't installed or the daemon isn't running, that
third block is skipped with a clear message; the unit and SQLite tests
still run.

## Bugs this caught during development

**UNKNOWN sorting as the *worst* status broke the SQLite backend's exit
code entirely.** The first version of `backend-sqlite.sh` reported
`STATUS_UNKNOWN` for `active_sessions`, `blocked_sessions`, and
`long_running_queries` — accurate in spirit ("this doesn't apply"), but
`report()` folds every status into `WORST_STATUS`, and in the Nagios
convention this toolkit follows, UNKNOWN (`3`) sorts higher than CRITICAL
(`2`). Three permanently-UNKNOWN checks meant the SQLite backend exited
`3` on *every single run*, no matter how healthy the database actually
was — a monitoring agent would treat a perfectly clean database the same
as a bad one, every time. Caught immediately by the first real test run
(`sqlite backend, clean db: exits 0` failed with "got 3"), not by
inspection. Fixed by printing those three as plain informational lines
that never call `report()`, so a designed-in skip no longer poisons the
exit code the way a real failure should.

**The `--json` subshell bug from `deploy-validator`, avoided by knowing to
look for it.** `deploy-validator`'s README documents a bug where
`out="$(run_all_checks)"` forks a subshell, silently discarding
`report()`'s updates to the run's counters. `bin/db-healthcheck`'s `--json`
path was written directly as `run_all_checks >/dev/null` (plain
redirection, no subshell) from the start — worth noting here because the
same bug was *also* found, independently, already live in
`windchill-ops-toolkit`'s `--json` and `--compare` modes while this project
was being built (see that project's git history), which is exactly the
kind of bug that passes review and only shows up when someone actually
runs the `--json` flag and checks the exit code, not just the text output.

## Requirements

Bash 3.2+, `psql` for the postgres backend, `sqlite3` for the sqlite
backend, `sqlplus` for the (unverified) oracle backend. `jq` is optional —
only used by the test suite to validate `--json` output, not by the tool
itself. Tests additionally need Docker for the Postgres integration
scenarios; without it, those scenarios are skipped and the rest of the
suite still runs. Tested on macOS (bash 3.2, the version macOS ships for
licensing reasons) with Postgres running in Docker Desktop.

## Scope and limitations

This checks database-level health signals visible through ordinary SQL —
it does not touch OS-level resources (that's `windchill-ops-toolkit`'s
job) or verify the schema matches what an application expects (that's
closer to `deploy-validator`'s territory). The Oracle backend in
particular should be treated as a starting point for real testing, not as
a finished, trustworthy implementation — see the table at the top of this
file.
