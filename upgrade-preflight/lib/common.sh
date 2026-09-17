#!/usr/bin/env bash
# common.sh - shared helpers: colors, logging, result tracking, the report()
# primitive every check funnels through.
#
# Deliberately the same shape as deploy-validator/lib/common.sh -- this
# tool is deploy-validator's before-the-change counterpart (preflight
# checks a host is ready to be upgraded; deploy-validator checks the
# upgrade actually landed), and reading as a matched pair matters more
# than either file being independently "better."

# --- colors (disabled automatically when not a tty) -------------------------
if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

die() { printf 'ERROR: %s\n' "$1" >&2; exit 3; }

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

# --- result tracking ----------------------------------------------------
# Every item checked is either PASS or FAIL -- a binary GO/NO-GO question,
# same as deploy-validator, unlike windchill-ops-toolkit's graduated
# OK/WARNING/CRITICAL scale (there's no "partially safe to upgrade").
ITEMS_TOTAL=0
ITEMS_PASS=0
ITEMS_FAIL=0
declare -a FAILURES=()

# report STATUS NAME MESSAGE
# STATUS is "PASS" or "FAIL". Prints the line, updates counters, and in
# --strict mode exits immediately on the first failure.
report() {
  local status="$1" name="$2" msg="$3"
  ((ITEMS_TOTAL++))

  local color line
  case "$status" in
    PASS) color="$C_GREEN"; ((ITEMS_PASS++)) ;;
    FAIL) color="$C_RED";   ((ITEMS_FAIL++)); FAILURES+=("${name}: ${msg}") ;;
    *)    color="$C_YELLOW" ;;
  esac

  line=$(printf '[%s%-4s%s] %-28s %s' "$color" "$status" "$C_RESET" "$name" "$msg")
  printf '%s\n' "$line"

  if [[ "$status" == "FAIL" && "${STRICT:-false}" == "true" ]]; then
    printf '\n%sstrict mode: stopping on first failure%s\n' "$C_DIM" "$C_RESET"
    print_summary
    exit 1
  fi
}

print_summary() {
  printf '\n%sSummary%s\n' "$C_BOLD" "$C_RESET"
  printf '  items checked : %d\n' "$ITEMS_TOTAL"
  printf '  pass          : %d\n' "$ITEMS_PASS"
  printf '  fail          : %d\n' "$ITEMS_FAIL"

  if (( ITEMS_FAIL > 0 )); then
    printf '\n%sReasons for NO-GO%s\n' "$C_BOLD" "$C_RESET"
    local f
    for f in "${FAILURES[@]}"; do
      printf '  - %s\n' "$f"
    done
    printf '\n%sDECISION: NO-GO%s\n' "${C_RED}${C_BOLD}" "$C_RESET"
  else
    printf '\n%sDECISION: GO%s\n' "${C_GREEN}${C_BOLD}" "$C_RESET"
  fi
}
