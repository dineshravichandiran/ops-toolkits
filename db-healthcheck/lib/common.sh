#!/usr/bin/env bash
# common.sh - shared helpers for db-healthcheck.
# Sourced by every check/backend module. No side effects on source.

# Exit/status codes follow Nagios-style conventions, same as the other
# tools in this toolkit, so the output can be consumed by Zabbix, Nagios,
# or any monitoring agent without translation.
readonly STATUS_OK=0
readonly STATUS_WARN=1
readonly STATUS_CRIT=2
readonly STATUS_UNKNOWN=3

# Colour only when attached to a terminal, so piped/redirected output stays clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_CRIT=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_OK=''; C_WARN=''; C_CRIT=''; C_DIM=''; C_BOLD=''
fi

# Accumulators for the run summary. Plain assignment, not `declare -g`:
# this file is sourced at top-level scope, where a plain assignment is
# already global -- and `-g` requires bash 4+, which macOS's shipped
# /bin/bash (3.2, GPLv3 licensing) doesn't have.
CHECKS_RUN=0
CHECKS_OK=0
CHECKS_WARN=0
CHECKS_CRIT=0
WORST_STATUS=$STATUS_OK

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# report <status> <check-name> <message>
# Single place that formats results, tallies counts, and tracks the worst
# status seen, so the script's exit code reflects the whole run.
report() {
  local status="$1" name="$2" msg="$3" label colour
  case "$status" in
    "$STATUS_OK")    label="OK";       colour="$C_OK";   ((CHECKS_OK++))   ;;
    "$STATUS_WARN")  label="WARNING";  colour="$C_WARN"; ((CHECKS_WARN++)) ;;
    "$STATUS_CRIT")  label="CRITICAL"; colour="$C_CRIT"; ((CHECKS_CRIT++)) ;;
    *)               label="UNKNOWN";  colour="$C_WARN"; ((CHECKS_WARN++)) ;;
  esac
  ((CHECKS_RUN++))
  (( status > WORST_STATUS )) && WORST_STATUS=$status
  printf '%s[%-8s]%s %-28s %s\n' "$colour" "$label" "$C_RESET" "$name" "$msg"
}

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

die() { printf 'ERROR: %s\n' "$1" >&2; exit "$STATUS_UNKNOWN"; }

print_summary() {
  section "Summary"
  printf '  checks run : %d\n' "$CHECKS_RUN"
  printf '  ok         : %d\n' "$CHECKS_OK"
  printf '  warning    : %d\n' "$CHECKS_WARN"
  printf '  critical   : %d\n' "$CHECKS_CRIT"
  printf '  finished   : %s\n' "$(log_ts)"
}

# classify <value> <warn> <crit>
# Shared threshold logic: value >= crit -> CRITICAL, >= warn -> WARNING,
# else OK. Every count/size-based check funnels through this so the
# boundary behaviour is identical (and identically tested) everywhere.
classify() {
  local value="$1" warn="$2" crit="$3"
  if   (( value >= crit )); then echo "$STATUS_CRIT"
  elif (( value >= warn )); then echo "$STATUS_WARN"
  else                           echo "$STATUS_OK"
  fi
}

# read_secret <VAR_NAME> <VAR_NAME_FILE>
# Resolves a credential from either an env var or a file path held in a
# second env var (e.g. DB_HEALTHCHECK_PASSWORD_FILE=/run/secrets/db-pass),
# so a password never has to be written into a config file or a CLI arg
# (CLI args are visible to anyone on the box via `ps`). Prints nothing and
# returns 1 if neither is set -- callers decide whether that's fatal.
read_secret() {
  local var_name="$1" file_var_name="$2"
  local val="${!var_name:-}"
  local file_val="${!file_var_name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  elif [[ -n "$file_val" ]]; then
    [[ -r "$file_val" ]] || die "cannot read secret file: $file_val"
    # Trim a single trailing newline, as most secret-file conventions do.
    printf '%s' "$(cat "$file_val")"
  else
    return 1
  fi
}
