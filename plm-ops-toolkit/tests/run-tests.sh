#!/usr/bin/env bash
# run-tests.sh - self-contained tests. No external framework needed.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/checks.sh"

PASS=0; FAIL=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (expected "%s", got "%s")\n' "$name" "$expected" "$actual"; ((FAIL++))
  fi
}

echo "Running tests"
echo

# --- threshold boundaries ---------------------------------------------------
classify() {
  local pct="$1" warn="$2" crit="$3"
  if   (( pct >= crit )); then echo "CRITICAL"
  elif (( pct >= warn )); then echo "WARNING"
  else echo "OK"; fi
}
assert_eq "OK"       "$(classify 74 75 90)" "74% below warn threshold"
assert_eq "WARNING"  "$(classify 75 75 90)" "75% hits warn boundary"
assert_eq "WARNING"  "$(classify 89 75 90)" "89% still warn"
assert_eq "CRITICAL" "$(classify 90 75 90)" "90% hits crit boundary"
assert_eq "CRITICAL" "$(classify 99 75 90)" "99% critical"

# --- Xmx parsing ------------------------------------------------------------
parse_xmx() {
  local cmd="$1" mb=0
  if [[ "$cmd" =~ -Xmx([0-9]+)([gGmM]) ]]; then
    case "${BASH_REMATCH[2]}" in
      g|G) mb=$(( BASH_REMATCH[1] * 1024 )) ;;
      m|M) mb=${BASH_REMATCH[1]} ;;
    esac
  fi
  echo "$mb"
}
assert_eq "4096" "$(parse_xmx 'java -Xmx4g Foo')"    "-Xmx4g parses to 4096MB"
assert_eq "2048" "$(parse_xmx 'java -Xmx2G Foo')"    "-Xmx2G uppercase parses"
assert_eq "512"  "$(parse_xmx 'java -Xmx512m Foo')"  "-Xmx512m parses"
assert_eq "0"    "$(parse_xmx 'java Foo')"           "missing -Xmx yields 0"

# --- dry-run guard ----------------------------------------------------------
DRY_RUN=true
if confirm_or_skip "test action" >/dev/null; then
  printf '  FAIL  dry-run guard should block actions\n'; ((FAIL++))
else
  printf '  PASS  dry-run guard blocks actions\n'; ((PASS++))
fi

DRY_RUN=false
if confirm_or_skip "test action" >/dev/null; then
  printf '  PASS  --apply allows actions\n'; ((PASS++))
else
  printf '  FAIL  --apply should allow actions\n'; ((FAIL++))
fi

# --- worst-status propagation ----------------------------------------------
CHECKS_RUN=0; CHECKS_OK=0; CHECKS_WARN=0; CHECKS_CRIT=0; WORST_STATUS=$STATUS_OK
report "$STATUS_OK"   "t1" "fine"     >/dev/null
report "$STATUS_WARN" "t2" "degraded" >/dev/null
assert_eq "1" "$WORST_STATUS" "worst status rises to WARNING"
report "$STATUS_CRIT" "t3" "down"     >/dev/null
assert_eq "2" "$WORST_STATUS" "worst status rises to CRITICAL"
report "$STATUS_OK"   "t4" "fine"     >/dev/null
assert_eq "2" "$WORST_STATUS" "worst status never decreases"
assert_eq "4" "$CHECKS_RUN"   "all checks counted"

# --- missing directories degrade gracefully --------------------------------
out="$(check_old_logs /nonexistent/path/xyz 2>&1)"
[[ "$out" == *"not present"* ]] \
  && { printf '  PASS  missing log dir handled gracefully\n'; ((PASS++)); } \
  || { printf '  FAIL  missing log dir not handled\n'; ((FAIL++)); }

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
