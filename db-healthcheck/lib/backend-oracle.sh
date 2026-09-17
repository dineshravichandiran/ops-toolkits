#!/usr/bin/env bash
# backend-oracle.sh - Oracle implementation of the check backend.
#
# *** UNVERIFIED: written against Oracle's documented data dictionary
# views, but never run against a real Oracle instance -- I don't have one
# available. The Postgres backend (backend-postgres.sh) is the one
# actually exercised by tests/run-tests.sh; this file exists to show the
# real queries this tool would use in production, and is included so the
# design (one query per check, same report()/classify() contract as every
# other backend) is concrete rather than hand-waved. See README.md,
# "Oracle vs. what was actually tested" for the full list of differences.
#
# Connects via `sqlplus` (Oracle's own CLI, the same role `psql` plays for
# Postgres) using SQLHOST/SQLPORT/SQLSERVICE/SQLUSER/SQLPASSWORD, set by
# bin/db-healthcheck from the same DB_HEALTHCHECK_* config this toolkit's
# other backends use.

oracle_query() {
  local sql="$1"
  sqlplus -s "${SQLUSER}/${SQLPASSWORD}@${SQLHOST}:${SQLPORT}/${SQLSERVICE}" <<SQL 2>&1
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF ECHO OFF VERIFY OFF TERMOUT ON TRIMSPOOL ON
SET COLSEP '|'
WHENEVER SQLERROR EXIT SQL.SQLCODE
${sql}
EXIT;
SQL
}

oracle_check_connectivity() {
  local out
  if ! out="$(oracle_query 'select 1 from dual;')"; then
    report "$STATUS_UNKNOWN" "db:connection" "cannot connect: ${out}"
    return 1
  fi
  return 0
}

# --- Tablespace usage ---------------------------------------------------
# The real thing: Oracle tablespaces are backed by datafiles with a
# genuine maximum size (either fixed, or AUTOEXTEND up to MAXSIZE), so
# percent-used is a first-class number computed straight from the data
# dictionary -- this is what backend-postgres.sh's MB-threshold approach
# is standing in for.
backend_check_tablespaces() {
  local warn="${TABLESPACE_WARN_PCT:-80}" crit="${TABLESPACE_CRIT_PCT:-90}"
  local rows
  rows="$(oracle_query "
    SELECT df.tablespace_name,
           ROUND(100 * (df.bytes - NVL(fs.bytes, 0)) / df.bytes)
    FROM (SELECT tablespace_name, SUM(bytes) bytes
          FROM dba_data_files GROUP BY tablespace_name) df
    LEFT JOIN (SELECT tablespace_name, SUM(bytes) bytes
               FROM dba_free_space GROUP BY tablespace_name) fs
      ON df.tablespace_name = fs.tablespace_name;
  ")" || { report "$STATUS_UNKNOWN" "db:tablespaces" "query failed: ${rows}"; return; }

  local name pct status
  while IFS='|' read -r name pct; do
    name="$(echo "$name" | xargs)"; pct="$(echo "$pct" | xargs)"
    [[ -z "$name" ]] && continue
    status="$(classify "$pct" "$warn" "$crit")"
    report "$status" "tablespace:${name}" "${pct}% used (warn >=${warn}%, crit >=${crit}%)"
  done <<< "$rows"
}

backend_check_active_sessions() {
  local warn="${SESSIONS_WARN:-50}" crit="${SESSIONS_CRIT:-100}"
  local count status
  count="$(oracle_query "SELECT COUNT(*) FROM v\$session WHERE status = 'ACTIVE' AND type != 'BACKGROUND';" | xargs)" || {
    report "$STATUS_UNKNOWN" "db:active_sessions" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:active_sessions" "${count} active session(s) (warn >=${warn}, crit >=${crit})"
}

backend_check_blocked_sessions() {
  local warn="${BLOCKED_WARN:-1}" crit="${BLOCKED_CRIT:-5}"
  local count status
  count="$(oracle_query "SELECT COUNT(*) FROM v\$session WHERE blocking_session IS NOT NULL;" | xargs)" || {
    report "$STATUS_UNKNOWN" "db:blocked_sessions" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:blocked_sessions" "${count} session(s) blocked on another session's lock (warn >=${warn}, crit >=${crit})"
}

backend_check_invalid_objects() {
  local warn="${INVALID_OBJECTS_WARN:-1}" crit="${INVALID_OBJECTS_CRIT:-5}"
  local count status
  count="$(oracle_query "SELECT COUNT(*) FROM dba_objects WHERE status = 'INVALID';" | xargs)" || {
    report "$STATUS_UNKNOWN" "db:invalid_objects" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:invalid_objects" "${count} invalid object(s) (warn >=${warn}, crit >=${crit})"
}

backend_check_long_running_queries() {
  local threshold="${LONG_QUERY_THRESHOLD_SEC:-300}"
  local warn="${LONG_QUERY_WARN:-1}" crit="${LONG_QUERY_CRIT:-3}"
  local count status
  # LAST_CALL_ET is seconds since the session's current call started while
  # ACTIVE -- the direct Oracle analog of Postgres's `now() - query_start`.
  count="$(oracle_query "SELECT COUNT(*) FROM v\$session WHERE status = 'ACTIVE' AND type != 'BACKGROUND' AND last_call_et > ${threshold};" | xargs)" || {
    report "$STATUS_UNKNOWN" "db:long_running_queries" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:long_running_queries" "${count} query(ies) running longer than ${threshold}s (warn >=${warn}, crit >=${crit})"
}

backend_run_all_checks() {
  printf '%s*** Oracle backend is UNVERIFIED: written against documented data dictionary views, never run against a real Oracle instance. See README.md. ***%s\n' "$C_WARN" "$C_RESET"

  section "Connectivity"
  oracle_check_connectivity || return

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
