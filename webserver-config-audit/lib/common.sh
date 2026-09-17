#!/usr/bin/env bash
# common.sh - shared helpers for webserver-config-audit.
#
# Three-state PASS/WARN/FAIL, not the binary PASS/FAIL of deploy-validator
# or upgrade-preflight: a config audit run by a human benefits from a
# distinct "couldn't confirm this one way or the other, go check by hand"
# signal (WARN) that a plain pass/fail would silently collapse into
# either a false-clean PASS or an alarming FAIL. deploy-validator and
# upgrade-preflight are pipeline gates where that ambiguity doesn't have
# anywhere to go; this tool is read by a person, so it can afford a
# middle state.
#
# Exit codes: 0 clean (PASS only), 1 WARN present (no FAIL), 2 FAIL
# present. Worst result wins, same "worst status sticks" idea as the
# other tools in this toolkit, just with three levels instead of two or
# four.

if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

die() { printf 'ERROR: %s\n' "$1" >&2; exit 3; }

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

ITEMS_TOTAL=0
ITEMS_PASS=0
ITEMS_WARN=0
ITEMS_FAIL=0
declare -a FINDINGS=()

# report STATUS NAME MESSAGE
# STATUS is PASS, WARN, or FAIL.
report() {
  local status="$1" name="$2" msg="$3" color
  ((ITEMS_TOTAL++))

  case "$status" in
    PASS) color="$C_GREEN"; ((ITEMS_PASS++)) ;;
    WARN) color="$C_YELLOW"; ((ITEMS_WARN++)); FINDINGS+=("WARN|${name}: ${msg}") ;;
    FAIL) color="$C_RED";   ((ITEMS_FAIL++)); FINDINGS+=("FAIL|${name}: ${msg}") ;;
    *)    color="$C_YELLOW" ;;
  esac

  printf '[%s%-4s%s] %-32s %s\n' "$color" "$status" "$C_RESET" "$name" "$msg"
}

# _lc <string> -- lowercase, portably. `${var,,}` is bash 4+ only and
# breaks on macOS's shipped bash 3.2; `tr` works identically everywhere.
_lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

print_summary() {
  printf '\n%sSummary%s\n' "$C_BOLD" "$C_RESET"
  printf '  items checked : %d\n' "$ITEMS_TOTAL"
  printf '  pass          : %d\n' "$ITEMS_PASS"
  printf '  warn          : %d\n' "$ITEMS_WARN"
  printf '  fail          : %d\n' "$ITEMS_FAIL"

  if (( ITEMS_FAIL > 0 || ITEMS_WARN > 0 )); then
    printf '\n%sFindings%s\n' "$C_BOLD" "$C_RESET"
    local entry status msg
    for entry in "${FINDINGS[@]}"; do
      status="${entry%%|*}"; msg="${entry#*|}"
      printf '  [%s] %s\n' "$status" "$msg"
    done
  fi

  if   (( ITEMS_FAIL > 0 )); then printf '\n%sOVERALL: FAIL%s\n' "${C_RED}${C_BOLD}" "$C_RESET"
  elif (( ITEMS_WARN > 0 )); then printf '\n%sOVERALL: WARN%s\n' "${C_YELLOW}${C_BOLD}" "$C_RESET"
  else                            printf '\n%sOVERALL: PASS%s\n' "${C_GREEN}${C_BOLD}" "$C_RESET"
  fi
}

exit_code() {
  if   (( ITEMS_FAIL > 0 )); then echo 2
  elif (( ITEMS_WARN > 0 )); then echo 1
  else                            echo 0
  fi
}
