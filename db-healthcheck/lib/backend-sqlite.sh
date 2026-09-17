#!/usr/bin/env bash
# backend-sqlite.sh - SQLite implementation of the check backend.
#
# SQLite is not a server: there is no concurrent-session concept, no lock
# table to inspect from outside the one process holding the write lock,
# and no tablespace concept at all. This backend exists purely as a
# zero-dependency way to exercise db-healthcheck's plumbing (config
# loading, threshold classification, report formatting, --json, exit
# codes) without Docker or a network database -- per README.md, it is
# NOT a stand-in for Oracle's session/lock/tablespace checks the way the
# Postgres backend is. Checks that have no honest SQLite equivalent report
# UNKNOWN with an explanation instead of faking a number.

sqlite_query() {
  local sql="$1"
  sqlite3 -separator '|' "$SQLITE_DB_PATH" "$sql" 2>&1
}

sqlite_check_connectivity() {
  [[ -n "${SQLITE_DB_PATH:-}" ]] || { report "$STATUS_UNKNOWN" "db:connection" "SQLITE_DB_PATH is not set"; return 1; }
  [[ -r "$SQLITE_DB_PATH" ]] || { report "$STATUS_UNKNOWN" "db:connection" "cannot read SQLITE_DB_PATH: ${SQLITE_DB_PATH}"; return 1; }
  local out
  if ! out="$(sqlite_query 'select 1;')"; then
    report "$STATUS_UNKNOWN" "db:connection" "cannot query: ${out}"
    return 1
  fi
  return 0
}

# --- "Tablespace" usage -------------------------------------------------
# Stand-in: the size of the single database file on disk, since that's the
# only thing SQLite has that plays the same operational role (it's what
# fills up). Reported under the synthetic name "file" rather than a real
# tablespace name.
backend_check_tablespaces() {
  local warn="${TABLESPACE_WARN_MB:-1024}" crit="${TABLESPACE_CRIT_MB:-5120}"
  local bytes mb status
  bytes="$(wc -c < "$SQLITE_DB_PATH" | tr -d ' ')"
  mb=$(( bytes / 1024 / 1024 ))
  status="$(classify "$mb" "$warn" "$crit")"
  report "$status" "tablespace:file" "${mb}MB (warn >=${warn}MB, crit >=${crit}MB)"
}

# Deliberately NOT `report "$STATUS_UNKNOWN" ...` here: in the Nagios
# convention this toolkit follows, UNKNOWN (3) sorts as the *worst*
# status, worse than CRITICAL -- report() folding these into WORST_STATUS
# would make the sqlite backend permanently exit 3 no matter how healthy
# the database is, since these two checks have no applicable answer by
# design, every single run. That's not a health signal, it's a skip, so
# it's printed directly and left out of the run's totals and exit code.
backend_check_active_sessions() {
  printf '  (not applicable to SQLite: no server process, no session table)\n'
}

backend_check_blocked_sessions() {
  printf '  (not applicable to SQLite: single-writer file lock, no per-session wait state)\n'
}

# --- Object validity ---------------------------------------------------
# The closest real signal SQLite has: PRAGMA integrity_check walks the
# whole database looking for structural corruption, and PRAGMA
# foreign_key_check finds rows that violate a declared foreign key. Both
# are genuine "this object can't be trusted" conditions, unlike the
# session/lock checks above which have no SQLite equivalent at all.
backend_check_invalid_objects() {
  local warn="${INVALID_OBJECTS_WARN:-1}" crit="${INVALID_OBJECTS_CRIT:-5}"
  local integrity fk_issues total status

  integrity="$(sqlite_query 'PRAGMA integrity_check;')"
  if [[ "$integrity" == "ok" ]]; then
    integrity=0
  else
    integrity=$(printf '%s\n' "$integrity" | grep -c .)
  fi

  fk_issues="$(sqlite_query 'PRAGMA foreign_key_check;')"
  if [[ -z "$fk_issues" ]]; then
    fk_issues=0
  else
    fk_issues=$(printf '%s\n' "$fk_issues" | grep -c .)
  fi

  total=$(( integrity + fk_issues ))
  status="$(classify "$total" "$warn" "$crit")"
  report "$status" "db:invalid_objects" "${total} issue(s): ${integrity} integrity, ${fk_issues} foreign-key (warn >=${warn}, crit >=${crit})"
}

backend_check_long_running_queries() {
  printf '  (not applicable to SQLite: no query log, no server-side session to sample)\n'
}

backend_run_all_checks() {
  section "Connectivity"
  sqlite_check_connectivity || return

  section "Tablespaces"
  backend_check_tablespaces

  section "Sessions"
  backend_check_active_sessions
  backend_check_blocked_sessions

  section "Object validity"
  backend_check_invalid_objects

  section "Long-running queries"
  backend_check_long_running_queries
}
