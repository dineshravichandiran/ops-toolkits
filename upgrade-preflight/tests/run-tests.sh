#!/usr/bin/env bash
# run-tests.sh - integration tests for upgrade-preflight.
#
# Builds real fixtures -- real files with real mtimes, a real background
# process with a unique marker, a real zombie process -- and runs the
# actual bin/upgrade-preflight against them. No mocking.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/bin/upgrade-preflight"

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${SERVICE_PID:-}" ]] && kill "$SERVICE_PID" >/dev/null 2>&1
  [[ -n "${ZOMBIE_HOLDER_PID:-}" ]] && kill "$ZOMBIE_HOLDER_PID" >/dev/null 2>&1
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

echo "Running tests"
echo

# =============================================================================
# Fixtures
# =============================================================================

mkdir -p "$WORK_DIR/app"
echo "3.3.7" > "$WORK_DIR/app/VERSION"

FRESH_BACKUP="$WORK_DIR/fresh-backup.tar.gz"
echo "backup contents" > "$FRESH_BACKUP"

STALE_BACKUP="$WORK_DIR/stale-backup.tar.gz"
echo "backup contents" > "$STALE_BACKUP"
# Portable across GNU/BSD touch: set mtime to 48 hours ago.
STALE_TS="$(date -v-48H '+%Y%m%d%H%M' 2>/dev/null || date -d '48 hours ago' '+%Y%m%d%H%M')"
touch -t "$STALE_TS" "$STALE_BACKUP"

# A long-lived background process with a unique marker, so the service
# check has something genuine and unambiguous to find -- same technique
# deploy-validator's own test suite uses.
SERVICE_MARKER="upf-test-service-marker-$$"
bash -c "exec -a '${SERVICE_MARKER}' sleep 300" &
SERVICE_PID=$!
sleep 0.2

# A real zombie process: a parent that backgrounds a child, then sleeps
# without reaping it, leaving the child a genuine zombie under a real,
# identifiable parent (the parent is named "sleep" via `exec -a`, which
# DOES show up in ps since the parent is still alive -- unlike a
# zombie's own name, which macOS's ps reports as a bare "<defunct>").
ZOMBIE_PARENT_MARKER="upf-test-zombie-parent-$$"
bash -c "
  sleep 0 &
  exec -a '${ZOMBIE_PARENT_MARKER}' sleep 10
" &
ZOMBIE_HOLDER_PID=$!
sleep 0.5

# =============================================================================
# Scenario 1: fully-passing manifest
# =============================================================================
cat > "$WORK_DIR/manifest-pass.yaml" <<EOF
disk_space:
  - path: ${WORK_DIR}
    min_free_mb: 1
backups:
  - path: ${FRESH_BACKUP}
    max_age_hours: 24
versions:
  - source: file
    path: ${WORK_DIR}/app/VERSION
    pattern: "3.3."
services:
  - name: ${SERVICE_MARKER}
    expected_state: running
  - name: definitely-not-running-$$
    expected_state: stopped
zombie_patterns:
  - definitely-no-such-parent-$$
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-pass.yaml")"; code=$?
assert_exit "0" "$code" "fully-passing manifest: GO (exit 0)"
assert_contains "$out" "DECISION: GO" "fully-passing manifest reports DECISION: GO"
assert_contains "$out" "items checked : 6" "fully-passing manifest checked all 6 items"

# =============================================================================
# Scenario 2: disk space -- both directions
# =============================================================================
cat > "$WORK_DIR/manifest-disk-fail.yaml" <<EOF
disk_space:
  - path: ${WORK_DIR}
    min_free_mb: 999999999
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-disk-fail.yaml")"; code=$?
assert_exit "1" "$code" "impossible disk requirement: NO-GO"
assert_contains "$out" "need >=999999999MB" "impossible disk requirement names the shortfall"

cat > "$WORK_DIR/manifest-disk-missing.yaml" <<EOF
disk_space:
  - path: ${WORK_DIR}/no-such-directory
    min_free_mb: 1
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-disk-missing.yaml")"; code=$?
assert_exit "1" "$code" "nonexistent disk path: NO-GO"
assert_contains "$out" "path does not exist" "nonexistent disk path is reported clearly"

# =============================================================================
# Scenario 3: backup freshness -- both directions
# =============================================================================
cat > "$WORK_DIR/manifest-backup-stale.yaml" <<EOF
backups:
  - path: ${STALE_BACKUP}
    max_age_hours: 24
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-backup-stale.yaml")"; code=$?
assert_exit "1" "$code" "48h-old backup against a 24h policy: NO-GO"
assert_contains "$out" "older than 24h" "stale backup is reported clearly"

cat > "$WORK_DIR/manifest-backup-missing.yaml" <<EOF
backups:
  - path: ${WORK_DIR}/no-such-backup.tar.gz
    max_age_hours: 24
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-backup-missing.yaml")"; code=$?
assert_exit "1" "$code" "missing backup file: NO-GO"
assert_contains "$out" "backup file not found" "missing backup is reported clearly"

# =============================================================================
# Scenario 4: version check -- file source and command source
# =============================================================================
cat > "$WORK_DIR/manifest-version-wrong.yaml" <<EOF
versions:
  - source: file
    path: ${WORK_DIR}/app/VERSION
    pattern: "9.9.9"
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-version-wrong.yaml")"; code=$?
assert_exit "1" "$code" "wrong expected current version: NO-GO"
assert_contains "$out" "expected current version '9.9.9' not found" "wrong version is reported clearly"

cat > "$WORK_DIR/manifest-version-command.yaml" <<EOF
versions:
  - source: command
    command: "echo v3.3.7-build42"
    pattern: "3.3.7"
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-version-command.yaml")"; code=$?
assert_exit "0" "$code" "command-sourced version check: GO"
assert_contains "$out" "found expected current version '3.3.7'" "command-sourced version is matched"

cat > "$WORK_DIR/manifest-version-no-pattern.yaml" <<EOF
versions:
  - source: file
    path: ${WORK_DIR}/app/VERSION
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-version-no-pattern.yaml")"; code=$?
assert_exit "0" "$code" "version check with no pattern is a pure detection check: GO"
assert_contains "$out" "detected: 3.3.7" "detected-only version check reports what it found"

# =============================================================================
# Scenario 5: services -- expected_state running and stopped, both directions
# =============================================================================
cat > "$WORK_DIR/manifest-service-wrong-state.yaml" <<EOF
services:
  - name: ${SERVICE_MARKER}
    expected_state: stopped
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-service-wrong-state.yaml")"; code=$?
assert_exit "1" "$code" "service running when it should be stopped: NO-GO"
assert_contains "$out" "expected stopped, but still running" "wrongly-running service is reported clearly"

cat > "$WORK_DIR/manifest-service-not-running.yaml" <<EOF
services:
  - name: definitely-not-running-$$
    expected_state: running
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-service-not-running.yaml")"; code=$?
assert_exit "1" "$code" "service expected running but isn't: NO-GO"
assert_contains "$out" "expected running, but not running" "wrongly-stopped service is reported clearly"

# =============================================================================
# Scenario 6: zombie processes, matched by parent name
# =============================================================================
cat > "$WORK_DIR/manifest-zombie-present.yaml" <<EOF
zombie_patterns:
  - ${ZOMBIE_PARENT_MARKER}
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-zombie-present.yaml")"; code=$?
assert_exit "1" "$code" "real zombie under a matching parent: NO-GO"
assert_contains "$out" "zombie process(es) under a parent matching" "zombie is reported by its parent's name, not its own (already-gone) name"

cat > "$WORK_DIR/manifest-zombie-absent.yaml" <<EOF
zombie_patterns:
  - no-such-parent-name-$$
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-zombie-absent.yaml")"; code=$?
assert_exit "0" "$code" "no zombie under a non-matching parent: GO"

# =============================================================================
# Scenario 7: multiple simultaneous failures, --strict, --json
# =============================================================================
cat > "$WORK_DIR/manifest-multi-fail.yaml" <<EOF
disk_space:
  - path: ${WORK_DIR}/no-such-directory
    min_free_mb: 1
backups:
  - path: ${WORK_DIR}/no-such-backup.tar.gz
    max_age_hours: 24
services:
  - name: definitely-not-running-$$
    expected_state: running
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml")"; code=$?
assert_exit "1" "$code" "multiple simultaneous failures: NO-GO"
assert_contains "$out" "items checked : 3" "default mode checks every item, not just the first"
assert_contains "$out" "fail          : 3" "all 3 failures counted"
fail_count=$(grep -c '^  - ' <<< "$out")
assert_exit "3" "$fail_count" "all 3 failures listed under Reasons for NO-GO"

out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml" --strict)"; code=$?
assert_exit "1" "$code" "--strict still exits 1"
assert_contains "$out" "stopping on first failure" "--strict announces early stop"
assert_contains "$out" "items checked : 1" "--strict stops after the first item, not all 3"

json_out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml" --json)"; code=$?
assert_exit "1" "$code" "--json still exits 1"
assert_contains "$json_out" '"items_total": 3' "--json reports correct items_total"
assert_contains "$json_out" '"items_fail": 3' "--json reports correct items_fail"
assert_contains "$json_out" '"decision": "NO-GO"' "--json reports decision NO-GO"
if command -v jq >/dev/null 2>&1; then
  if echo "$json_out" | jq -e . >/dev/null 2>&1; then
    printf '  PASS  %s\n' "--json output is valid JSON (parsed with jq)"; ((PASS++))
  else
    printf '  FAIL  %s\n' "--json output is not valid JSON"; ((FAIL++))
  fi
fi

# =============================================================================
# Scenario 8: JSON-format manifest and usage errors
# =============================================================================
cat > "$WORK_DIR/manifest.json" <<EOF
{
  "versions": [
    { "source": "file", "path": "${WORK_DIR}/app/VERSION", "pattern": "3.3." }
  ],
  "services": [
    { "name": "${SERVICE_MARKER}", "expected_state": "running" }
  ]
}
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest.json")"; code=$?
assert_exit "0" "$code" "JSON-format manifest is parsed and passes"

"$BIN" --manifest /no/such/manifest.yaml >/dev/null 2>&1; code=$?
assert_exit "2" "$code" "nonexistent manifest path exits 2"

"$BIN" >/dev/null 2>&1; code=$?
assert_exit "2" "$code" "missing --manifest argument exits 2"

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
