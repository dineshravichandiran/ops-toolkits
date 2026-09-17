#!/usr/bin/env bash
#
# plm-healthcheck.sh - pre-change and post-change health checks for
# Windchill-style application hosts (Apache, Tomcat, JVM, disk, logs).
#
# Designed around the sequence used for controlled production changes:
#   1. run before a change to capture a known-good baseline
#   2. apply the change
#   3. run again afterwards and diff against the baseline
#
# Safe by default: reports only. Cleanup requires an explicit --apply.
#
# Exit codes (Nagios convention, so monitoring agents can consume directly):
#   0 OK    1 WARNING    2 CRITICAL    3 UNKNOWN
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh" || { echo "cannot source lib/common.sh" >&2; exit 3; }
# shellcheck source=../lib/checks.sh
source "${ROOT_DIR}/lib/checks.sh" || die "cannot source lib/checks.sh"

DRY_RUN=true
BASELINE_FILE=""
OUTPUT_MODE="text"

usage() {
  cat <<'EOF'
Usage: plm-healthcheck.sh [OPTIONS]

  --apply                Perform cleanup actions. Default is report-only.
  --baseline FILE        Write results to FILE for later comparison.
  --compare FILE         Compare this run against a previous baseline file.
  --json                 Emit machine-readable JSON instead of text.
  -h, --help             Show this help.

Examples:
  # Capture a baseline before a change window
  ./plm-healthcheck.sh --baseline /tmp/pre-change.txt

  # Validate after the change and diff against the baseline
  ./plm-healthcheck.sh --compare /tmp/pre-change.txt

  # Routine maintenance run that actually reclaims old logs
  ./plm-healthcheck.sh --apply
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     DRY_RUN=false; shift ;;
    --baseline)  BASELINE_FILE="${2:-}"; [[ -z "$BASELINE_FILE" ]] && die "--baseline needs a path"; shift 2 ;;
    --compare)   COMPARE_FILE="${2:-}"; [[ -z "$COMPARE_FILE" ]] && die "--compare needs a path"; shift 2 ;;
    --json)      OUTPUT_MODE="json"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
done

# Load config if present; otherwise defaults in the check functions apply.
CONF="${ROOT_DIR}/conf/toolkit.conf"
if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  source "$CONF"
else
  LOG_DIRS="${LOG_DIRS:-/var/log}"
  TEMP_DIRS="${TEMP_DIRS:-/tmp}"
  SERVICES="${SERVICES:-httpd:httpd tomcat:catalina}"
  PORTS="${PORTS:-}"
  HTTP_ENDPOINTS="${HTTP_ENDPOINTS:-}"
  JVM_PROCESS_PATTERN="${JVM_PROCESS_PATTERN:-java}"
fi

run_all_checks() {
  printf '%sPLM host health check%s  |  %s  |  %s\n' \
    "$C_BOLD" "$C_RESET" "$(hostname)" "$(log_ts)"
  [[ "$DRY_RUN" == "true" ]] && printf '%smode: report-only (use --apply to perform cleanup)%s\n' "$C_DIM" "$C_RESET"

  section "Filesystem"
  check_disk_usage

  section "Services"
  for entry in $SERVICES; do
    check_service "${entry%%:*}" "${entry##*:}"
  done

  if [[ -n "${PORTS:-}" ]]; then
    section "Ports"
    for entry in $PORTS; do
      IFS=':' read -r h p l <<< "$entry"
      check_port "$h" "$p" "${l:-$h:$p}"
    done
  fi

  section "JVM"
  check_jvm_memory "$JVM_PROCESS_PATTERN"

  section "Logs and temporary files"
  for d in $LOG_DIRS;  do check_old_logs  "$d"; done
  for d in $TEMP_DIRS; do check_temp_files "$d"; done

  if [[ -n "${HTTP_ENDPOINTS:-}" ]]; then
    section "Endpoints"
    for entry in $HTTP_ENDPOINTS; do
      check_http_endpoint "${entry%:*}" "${entry##*:}"
    done
  fi

  print_summary
}

if [[ "$OUTPUT_MODE" == "json" ]]; then
  # Strip ANSI and re-emit as JSON for monitoring ingestion.
  raw="$(run_all_checks | sed 's/\x1b\[[0-9;]*m//g')"
  printf '{"host":"%s","timestamp":"%s","worst_status":%d,"checks_run":%d,"ok":%d,"warning":%d,"critical":%d}\n' \
    "$(hostname)" "$(log_ts)" "$WORST_STATUS" "$CHECKS_RUN" "$CHECKS_OK" "$CHECKS_WARN" "$CHECKS_CRIT"
  exit "$WORST_STATUS"
fi

if [[ -n "$BASELINE_FILE" ]]; then
  run_all_checks | tee "$BASELINE_FILE" | sed 's/\x1b\[[0-9;]*m//g' >/dev/null
  run_all_checks
  printf '\nbaseline written to %s\n' "$BASELINE_FILE"
elif [[ -n "${COMPARE_FILE:-}" ]]; then
  [[ -f "$COMPARE_FILE" ]] || die "baseline not found: $COMPARE_FILE"
  current="$(mktemp)"
  run_all_checks | sed 's/\x1b\[[0-9;]*m//g' > "$current"
  cat "$current"

  # Compare only check result lines. Timestamps, hostnames and the summary
  # block change on every run and would otherwise drown out real differences.
  strip_volatile() {
    sed 's/\x1b\[[0-9;]*m//g' "$1" \
      | grep -E '^\[(OK|WARNING|CRITICAL|UNKNOWN)' \
      | sed 's/[0-9]\+MB/NMB/g; s/[0-9]\+%/N%/g; s/[0-9]\+ file/N file/g; s/pid [0-9]\+/pid N/g'
  }

  section "Differences from baseline"
  if diff <(strip_volatile "$COMPARE_FILE") <(strip_volatile "$current") >/dev/null 2>&1; then
    printf '  no status changes detected\n'
  else
    diff <(strip_volatile "$COMPARE_FILE") <(strip_volatile "$current") \
      | grep -E '^[<>]' \
      | sed 's/^</  was:/; s/^>/  now:/' || true
  fi
  rm -f "$current"
else
  run_all_checks
fi

exit "$WORST_STATUS"
