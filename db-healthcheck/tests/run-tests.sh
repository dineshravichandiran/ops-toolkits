#!/usr/bin/env bash
# run-tests.sh - unit tests (no DB) plus real integration tests against a
# throwaway SQLite file and a real, disposable Postgres container. No SQL
# result is ever mocked: every assertion below reads what the real
# backend actually returned.
set -uo pipefail

# Harmless if psql is already on PATH; needed on a fresh macOS shell where
# libpq (which provides psql) was installed via `brew install libpq`,
# which is keg-only and not symlinked onto the default PATH.
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/bin/db-healthcheck"
source "${ROOT_DIR}/lib/common.sh"

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${LOCKER_PID:-}" ]] && kill "$LOCKER_PID" >/dev/null 2>&1
  [[ -n "${BLOCKED_PID:-}" ]] && kill "$BLOCKED_PID" >/dev/null 2>&1
  if [[ -n "${PG_CONTAINER:-}" ]]; then
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PASS=0; FAIL=0

assert_exit() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"; ((FAIL++))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (output did not contain: %s)\n' "$name" "$needle"; ((FAIL++))
  fi
}

assert_matches() {
  local haystack="$1" pattern="$2" name="$3"
  if [[ "$haystack" =~ $pattern ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (output did not match: %s)\n' "$name" "$pattern"; ((FAIL++))
  fi
}

echo "Running tests"
echo

# =============================================================================
# Unit tests -- pure bash, no database involved.
# =============================================================================

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (expected "%s", got "%s")\n' "$name" "$expected" "$actual"; ((FAIL++))
  fi
}

assert_eq "0" "$(classify 5 10 20)"   "classify below warn threshold is OK"
assert_eq "1" "$(classify 10 10 20)"  "classify at warn boundary is WARNING"
assert_eq "1" "$(classify 15 10 20)"  "classify between warn and crit is WARNING"
assert_eq "2" "$(classify 20 10 20)"  "classify at crit boundary is CRITICAL"
assert_eq "2" "$(classify 99 10 20)"  "classify above crit is CRITICAL"

# read_secret: env var, file, then neither.
DB_HEALTHCHECK_PASSWORD="from-env" DB_HEALTHCHECK_PASSWORD_FILE="" \
  out="$(DB_HEALTHCHECK_PASSWORD="from-env" bash -c 'source "'"${ROOT_DIR}"'/lib/common.sh"; read_secret DB_HEALTHCHECK_PASSWORD DB_HEALTHCHECK_PASSWORD_FILE')"
assert_eq "from-env" "$out" "read_secret prefers the env var"

echo "from-file" > "$WORK_DIR/secret.txt"
out="$(bash -c 'source "'"${ROOT_DIR}"'/lib/common.sh"; DB_HEALTHCHECK_PASSWORD_FILE="'"${WORK_DIR}"'/secret.txt"; read_secret DB_HEALTHCHECK_PASSWORD DB_HEALTHCHECK_PASSWORD_FILE')"
assert_eq "from-file" "$out" "read_secret falls back to the file"

bash -c 'source "'"${ROOT_DIR}"'/lib/common.sh"; read_secret DB_HEALTHCHECK_PASSWORD DB_HEALTHCHECK_PASSWORD_FILE' >/dev/null 2>&1
assert_exit "1" "$?" "read_secret fails when neither is set"

# =============================================================================
# SQLite backend -- real, local, no Docker required.
# =============================================================================

SQLITE_CLEAN="$WORK_DIR/clean.sqlite3"
sqlite3 "$SQLITE_CLEAN" "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER);" >/dev/null

out="$(DB_HEALTHCHECK_SQLITE_PATH="$SQLITE_CLEAN" "$BIN" --backend sqlite)"; code=$?
assert_exit "0" "$code" "sqlite backend, clean db: exits 0"
assert_contains "$out" "0 issue(s): 0 integrity, 0 foreign-key" "sqlite backend, clean db: reports zero invalid objects"
assert_contains "$out" "not applicable to SQLite: no server process" "sqlite backend: active_sessions is skipped, not faked, and doesn't affect the exit code"
assert_contains "$out" "not applicable to SQLite: single-writer" "sqlite backend: blocked_sessions is skipped, not faked"
assert_contains "$out" "not applicable to SQLite: no query log" "sqlite backend: long_running_queries is skipped, not faked"
assert_contains "$out" "tablespace:file" "sqlite backend: reports the db file size as the tablespace stand-in"

# A real foreign-key violation, inserted with enforcement off (SQLite
# allows this by default) so PRAGMA foreign_key_check has something
# genuine to find -- not a mocked failure.
SQLITE_DIRTY="$WORK_DIR/dirty.sqlite3"
sqlite3 "$SQLITE_DIRTY" <<'SQL' >/dev/null
CREATE TABLE authors (id INTEGER PRIMARY KEY);
CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id));
INSERT INTO authors (id) VALUES (1);
INSERT INTO books (id, author_id) VALUES (1, 99);
SQL

out="$(DB_HEALTHCHECK_SQLITE_PATH="$SQLITE_DIRTY" "$BIN" --backend sqlite)"; code=$?
assert_exit "1" "$code" "sqlite backend, dangling FK: exits WARNING (1)"
assert_contains "$out" "1 issue(s): 0 integrity, 1 foreign-key" "sqlite backend, dangling FK: caught by PRAGMA foreign_key_check"

out="$(DB_HEALTHCHECK_SQLITE_PATH="$WORK_DIR/does-not-exist.sqlite3" "$BIN" --backend sqlite)"; code=$?
assert_exit "3" "$code" "sqlite backend, missing file: exits UNKNOWN (3)"

TABLESPACE_WARN_MB=0 out="$(TABLESPACE_WARN_MB=0 DB_HEALTHCHECK_SQLITE_PATH="$SQLITE_CLEAN" "$BIN" --backend sqlite)"
assert_contains "$out" "tablespace:file" "threshold override: TABLESPACE_WARN_MB=0 still runs the check"
assert_matches "$out" 'WARNING.*tablespace:file' "threshold override: TABLESPACE_WARN_MB=0 forces WARNING regardless of actual size"

json_out="$(DB_HEALTHCHECK_SQLITE_PATH="$SQLITE_CLEAN" "$BIN" --backend sqlite --json)"; code=$?
assert_exit "0" "$code" "sqlite backend --json: exits 0 on a clean db"
if command -v jq >/dev/null 2>&1; then
  if echo "$json_out" | jq -e . >/dev/null 2>&1; then
    printf '  PASS  %s\n' "--json output is valid JSON (parsed with jq)"; ((PASS++))
  else
    printf '  FAIL  %s\n' "--json output is not valid JSON"; ((FAIL++))
  fi
fi
assert_contains "$json_out" '"backend":"sqlite"' "--json reports the active backend"

"$BIN" --backend nonsense >/dev/null 2>&1; code=$?
assert_exit "3" "$code" "unknown backend exits UNKNOWN (3)"

"$BIN" --help >/dev/null 2>&1; code=$?
assert_exit "0" "$code" "--help exits 0"

# =============================================================================
# Postgres backend -- real, disposable container. Every scenario here is
# checked against genuine database state: a real unvalidated constraint,
# a real session holding a real lock, a real second session actually
# blocked on it.
# =============================================================================

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo
  echo "SKIPPED: Postgres integration tests (Docker not installed or not running)"
  echo
  printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
  (( FAIL == 0 )) || exit 1
  exit 0
fi

PG_CONTAINER="dbhc-test-pg-$$"
PG_PORT=$(( 40000 + ($$ % 10000) ))
PG_PASSWORD="dbhc-test-password"

docker run -d --name "$PG_CONTAINER" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_USER=dbhc -e POSTGRES_DB=dbhc_test \
  -p "${PG_PORT}:5432" postgres:16-alpine >/dev/null

export PGHOST=127.0.0.1 PGPORT="$PG_PORT" PGDATABASE=dbhc_test PGUSER=dbhc PGPASSWORD="$PG_PASSWORD"

ready=0
for _ in $(seq 1 30); do
  if psql -X -q -c 'select 1;' >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
(( ready == 1 )) || { echo "FATAL: Postgres test container never became ready"; exit 1; }

export DB_HEALTHCHECK_HOST=127.0.0.1 DB_HEALTHCHECK_PORT="$PG_PORT" DB_HEALTHCHECK_NAME=dbhc_test DB_HEALTHCHECK_USER=dbhc
export DB_HEALTHCHECK_PASSWORD="$PG_PASSWORD"

# --- Scenario: nothing going on yet -----------------------------------------
out="$("$BIN" --backend postgres)"; code=$?
assert_exit "0" "$code" "postgres backend, idle db: exits OK (0)"
assert_contains "$out" "0 active session(s)" "postgres backend, idle db: no active sessions besides our own"
assert_contains "$out" "0 session(s) waiting on a lock" "postgres backend, idle db: nothing blocked"
assert_contains "$out" "0 invalid object(s)" "postgres backend, idle db: no invalid objects yet"

# --- Fixture: a real unvalidated constraint (a genuine "invalid object") ---
psql -X -q -c "CREATE TABLE dbhc_fixture (id serial primary key, n int);" >/dev/null
psql -X -q -c "ALTER TABLE dbhc_fixture ADD CONSTRAINT n_positive CHECK (n > 0) NOT VALID;" >/dev/null

out="$("$BIN" --backend postgres)"; code=$?
assert_exit "1" "$code" "postgres backend, one NOT VALID constraint: exits WARNING (1)"
assert_contains "$out" "1 invalid object(s): 0 index(es), 1 constraint(s)" "postgres backend: unvalidated constraint counted as an invalid object"

# --- Fixture: a real session holding a real lock, and a second real
#     session actually blocked waiting for it. LOCKER also satisfies the
#     active-session and long-running-query checks for as long as it sleeps.
psql -X -q -c "BEGIN; LOCK TABLE dbhc_fixture IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(12);" >/dev/null 2>&1 &
LOCKER_PID=$!
sleep 2   # give LOCKER time to actually acquire the lock before BLOCKED tries

psql -X -q -c "SELECT * FROM dbhc_fixture;" >/dev/null 2>&1 &
BLOCKED_PID=$!
sleep 2   # give BLOCKED time to actually attempt the lock and start waiting

out="$(LONG_QUERY_THRESHOLD_SEC=1 "$BIN" --backend postgres)"; code=$?
assert_exit "1" "$code" "postgres backend, locker+blocked session: exits at least WARNING"
assert_matches "$out" 'active_sessions.*[1-9][0-9]* active session' "postgres backend: locker session counted as active"
assert_matches "$out" 'blocked_sessions.*[1-9][0-9]* session\(s\) waiting on a lock' "postgres backend: second session counted as genuinely blocked"
assert_matches "$out" 'long_running_queries.*[1-9][0-9]* query\(ies\) running longer than 1s' "postgres backend: locker's pg_sleep(12) counted as long-running past a 1s threshold"

json_out="$(LONG_QUERY_THRESHOLD_SEC=1 "$BIN" --backend postgres --json)"; code=$?
assert_exit "1" "$code" "postgres backend --json: worst_status reflected in exit code"
assert_contains "$json_out" '"worst_status":1' "postgres backend --json: worst_status field matches"
if command -v jq >/dev/null 2>&1; then
  if echo "$json_out" | jq -e . >/dev/null 2>&1; then
    printf '  PASS  %s\n' "postgres backend --json output is valid JSON"; ((PASS++))
  else
    printf '  FAIL  %s\n' "postgres backend --json output is not valid JSON"; ((FAIL++))
  fi
fi

wait "$LOCKER_PID" 2>/dev/null
wait "$BLOCKED_PID" 2>/dev/null
LOCKER_PID=""; BLOCKED_PID=""

# --- Threshold override: force WARNING on a count that would otherwise be OK
out="$(SESSIONS_WARN=0 SESSIONS_CRIT=999999 "$BIN" --backend postgres)"; code=$?
assert_exit "1" "$code" "SESSIONS_WARN=0 forces a WARNING even with normal session counts"

# --- Missing credentials refuses to run rather than guessing --------------
unset DB_HEALTHCHECK_PASSWORD
"$BIN" --backend postgres >/dev/null 2>&1; code=$?
assert_exit "3" "$code" "missing password (no env var, no file) exits UNKNOWN (3) instead of connecting with nothing"
export DB_HEALTHCHECK_PASSWORD="$PG_PASSWORD"

# --- Connectivity failure reports UNKNOWN, not a false OK/CRITICAL --------
out="$(DB_HEALTHCHECK_PORT=1 "$BIN" --backend postgres 2>&1)"; code=$?
assert_exit "3" "$code" "unreachable port exits UNKNOWN (3)"
assert_contains "$out" "cannot connect" "unreachable port is reported as a connection failure, not a check failure"

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
