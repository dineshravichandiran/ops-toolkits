#!/usr/bin/env bash
# backend-postgres.sh - PostgreSQL implementation of the check backend.
#
# This is the backend actually exercised by tests/run-tests.sh against a
# real Postgres instance. It also stands in for Oracle during development,
# per README.md -- see backend-oracle.sh for the real-Oracle queries this
# is approximating, and why they differ.
#
# Connection is via `psql`, using its native PG* environment variables
# (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD) so nothing here needs its
# own connection-string parsing. pg_query() runs read-only SQL and returns
# pipe-delimited rows; nothing in this file ever writes to the database it
# checks.

# pg_query <sql>
# Runs SQL via psql, tuples-only, unaligned, pipe-delimited fields. Each
# result row is printed on its own line as "field1|field2|...".
pg_query() {
  local sql="$1"
  psql -X -q -t -A -F'|' -v ON_ERROR_STOP=1 -c "$sql" 2>&1
}

pg_check_connectivity() {
  local out
  if ! out="$(pg_query 'select 1;')"; then
    report "$STATUS_UNKNOWN" "db:connection" "cannot connect: ${out}"
    return 1
  fi
  return 0
}

# --- Tablespace usage --------------------------------------------------------
# Oracle tablespaces are datafile-backed with an intrinsic max size, so
# "percent used" is a first-class, meaningful number straight out of
# DBA_TABLESPACES/DBA_DATA_FILES (see backend-oracle.sh). Postgres
# tablespaces are just directories with no built-in size ceiling, so there
# is no honest "percent used" to report. Rather than invent a fake
# percentage, this backend reports each tablespace's actual size in MB and
# classifies it against an operator-configured absolute threshold -- the
# same shape of decision ("is this getting big enough to worry about"),
# made with the numbers Postgres actually has.
backend_check_tablespaces() {
  local warn="${TABLESPACE_WARN_MB:-1024}" crit="${TABLESPACE_CRIT_MB:-5120}"
  local rows
  rows="$(pg_query "select spcname, pg_tablespace_size(spcname) from pg_tablespace;")" || {
    report "$STATUS_UNKNOWN" "db:tablespaces" "query failed: ${rows}"; return
  }

  local line name bytes mb status
  while IFS='|' read -r name bytes; do
    [[ -z "$name" ]] && continue
    mb=$(( bytes / 1024 / 1024 ))
    status="$(classify "$mb" "$warn" "$crit")"
    report "$status" "tablespace:${name}" "${mb}MB (warn >=${warn}MB, crit >=${crit}MB)"
  done <<< "$rows"
}

# --- Active sessions ---------------------------------------------------------
backend_check_active_sessions() {
  local warn="${SESSIONS_WARN:-50}" crit="${SESSIONS_CRIT:-100}"
  local count status
  count="$(pg_query "select count(*) from pg_stat_activity where state = 'active' and pid <> pg_backend_pid();")" || {
    report "$STATUS_UNKNOWN" "db:active_sessions" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:active_sessions" "${count} active session(s) (warn >=${warn}, crit >=${crit})"
}

# --- Blocked / waiting sessions ----------------------------------------------
backend_check_blocked_sessions() {
  local warn="${BLOCKED_WARN:-1}" crit="${BLOCKED_CRIT:-5}"
  local count status
  count="$(pg_query "select count(*) from pg_stat_activity where wait_event_type = 'Lock' and pid <> pg_backend_pid();")" || {
    report "$STATUS_UNKNOWN" "db:blocked_sessions" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:blocked_sessions" "${count} session(s) waiting on a lock (warn >=${warn}, crit >=${crit})"
}

# --- Invalid objects -----------------------------------------------------
# Oracle's analog is DBA_OBJECTS.STATUS = 'INVALID' -- a broken view,
# procedure, or trigger left in an unusable state, usually after a failed
# DDL change. Postgres has no single "invalid object" status, but the two
# closest real equivalents -- an index left half-built (indisvalid = false,
# typically from a killed CREATE INDEX CONCURRENTLY) and a constraint
# added NOT VALID and never validated -- are the same category of problem:
# an object that exists but can't be trusted to do its job.
backend_check_invalid_objects() {
  local warn="${INVALID_OBJECTS_WARN:-1}" crit="${INVALID_OBJECTS_CRIT:-5}"
  local invalid_idx invalid_con total status

  invalid_idx="$(pg_query "select count(*) from pg_index where not indisvalid;")" || {
    report "$STATUS_UNKNOWN" "db:invalid_objects" "query failed: ${invalid_idx}"; return
  }
  invalid_con="$(pg_query "select count(*) from pg_constraint where not convalidated;")" || {
    report "$STATUS_UNKNOWN" "db:invalid_objects" "query failed: ${invalid_con}"; return
  }

  total=$(( invalid_idx + invalid_con ))
  status="$(classify "$total" "$warn" "$crit")"
  report "$status" "db:invalid_objects" "${total} invalid object(s): ${invalid_idx} index(es), ${invalid_con} constraint(s) (warn >=${warn}, crit >=${crit})"
}

# --- Long-running queries -----------------------------------------------
backend_check_long_running_queries() {
  local threshold="${LONG_QUERY_THRESHOLD_SEC:-300}"
  local warn="${LONG_QUERY_WARN:-1}" crit="${LONG_QUERY_CRIT:-3}"
  local count status
  count="$(pg_query "select count(*) from pg_stat_activity where state = 'active' and pid <> pg_backend_pid() and query_start < now() - interval '${threshold} seconds';")" || {
    report "$STATUS_UNKNOWN" "db:long_running_queries" "query failed: ${count}"; return
  }
  status="$(classify "$count" "$warn" "$crit")"
  report "$status" "db:long_running_queries" "${count} query(ies) running longer than ${threshold}s (warn >=${warn}, crit >=${crit})"
}

backend_run_all_checks() {
  section "Connectivity"
  pg_check_connectivity || return

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
