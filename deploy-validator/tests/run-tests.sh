#!/usr/bin/env bash
# run-tests.sh - integration tests for deploy-validator.
#
# Builds real fixture files/manifests under a temp directory and runs the
# actual bin/deploy-validator against them, asserting on exit code and
# output content. No mocking: every scenario is a manifest checked against
# real files, real (or deliberately absent) processes, and a real local
# HTTP server.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/bin/deploy-validator"

WORK_DIR="$(mktemp -d)"
cleanup() {
  [[ -n "${HTTP_SERVER_PID:-}" ]] && kill "$HTTP_SERVER_PID" >/dev/null 2>&1
  [[ -n "${FIXTURE_PID:-}" ]] && kill "$FIXTURE_PID" >/dev/null 2>&1
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

# --- fixtures shared by several scenarios -----------------------------------
mkdir -p "$WORK_DIR/app/webapps/app/META-INF"
echo "app archive contents, version 3.4.0" > "$WORK_DIR/app/webapps/app.war"
echo "<Server/>" > "$WORK_DIR/app/server.xml"
echo "Implementation-Version: 3.4.0" > "$WORK_DIR/app/webapps/app/META-INF/MANIFEST.MF"

# A long-lived background process to check "service running" against,
# instead of relying on any specific real system service being present.
# Launched with a unique marker in its argv so pgrep -f can find it
# reliably and distinctly from anything else running on the box.
FIXTURE_MARKER="dv-test-fixture-marker-$$"
bash -c "exec -a '${FIXTURE_MARKER}' sleep 300" &
FIXTURE_PID=$!
sleep 0.2

# A local HTTP server to check endpoint validation against. Port is derived
# from this process's PID to avoid colliding with a stale server left over
# from a previous run. Run with --directory instead of wrapping in a `cd`
# subshell, so $! is python3's own PID and cleanup() can actually kill it
# (a subshelled "(cd ... && cmd) &" backgrounds the subshell, not cmd, and
# once the subshell exits the recorded PID no longer controls the process).
HTTP_PORT=$(( 20000 + ($$ % 20000) ))
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK_DIR" >/dev/null 2>&1 &
HTTP_SERVER_PID=$!
sleep 1

# ============================================================================
# Scenario 1: fully-passing manifest
# ============================================================================
cat > "$WORK_DIR/manifest-pass.yaml" <<EOF
files:
  - path: ${WORK_DIR}/app/webapps/app.war
    version: "3.4.0"
  - path: ${WORK_DIR}/app/server.xml
version_checks:
  - path: ${WORK_DIR}/app/webapps/app/META-INF/MANIFEST.MF
    pattern: "Implementation-Version: 3.4.0"
services:
  - ${FIXTURE_MARKER}
endpoints:
  - url: "http://127.0.0.1:${HTTP_PORT}/"
    expected_status: 200
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-pass.yaml")"; code=$?
assert_exit "0" "$code" "fully-passing manifest exits 0"
assert_contains "$out" "OVERALL: PASS" "fully-passing manifest reports OVERALL: PASS"
# 2 files + 2 version checks (one from files[].version, one from
# version_checks[]) + 1 service + 1 endpoint = 6 items.
assert_contains "$out" "items checked : 6" "fully-passing manifest checked all 6 items"

# ============================================================================
# Scenario 2: missing file
# ============================================================================
cat > "$WORK_DIR/manifest-missing-file.yaml" <<EOF
files:
  - path: ${WORK_DIR}/app/webapps/app.war
  - path: ${WORK_DIR}/app/does-not-exist.conf
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-missing-file.yaml")"; code=$?
assert_exit "1" "$code" "manifest with missing file exits 1"
assert_contains "$out" "expected file not found" "missing file is reported as FAIL"
assert_contains "$out" "does-not-exist.conf" "missing file's path appears in output"

# ============================================================================
# Scenario 3: wrong version string
# ============================================================================
cat > "$WORK_DIR/manifest-wrong-version.yaml" <<EOF
files:
  - path: ${WORK_DIR}/app/webapps/app.war
    version: "9.9.9"
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-wrong-version.yaml")"; code=$?
assert_exit "1" "$code" "manifest with wrong version string exits 1"
assert_contains "$out" "expected string '9.9.9' not found" "wrong version is reported as FAIL"

# ============================================================================
# Scenario 4: service not running
# ============================================================================
cat > "$WORK_DIR/manifest-bad-service.yaml" <<EOF
services:
  - definitely-not-a-real-service-$$
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-bad-service.yaml")"; code=$?
assert_exit "1" "$code" "manifest with service not running exits 1"
assert_contains "$out" "not running" "absent service is reported as FAIL"

# ============================================================================
# Scenario 5: bad HTTP response
# ============================================================================
cat > "$WORK_DIR/manifest-bad-http.yaml" <<EOF
endpoints:
  - url: "http://127.0.0.1:${HTTP_PORT}/this-path-does-not-exist"
    expected_status: 200
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-bad-http.yaml")"; code=$?
assert_exit "1" "$code" "manifest with bad HTTP response exits 1"
assert_contains "$out" "HTTP 404, expected 200" "wrong HTTP status is reported as FAIL"

# Regression test: an endpoint that refuses the connection entirely (rather
# than responding with a wrong status) must report a clean "no response or
# timeout", not a mangled code. curl writes "000" via -w AND exits non-zero
# on connection failure; capturing with `curl ... || echo "000"` double-
# counted that case into "000000". Use a port nothing is listening on.
UNUSED_PORT=$(( HTTP_PORT + 1 ))
cat > "$WORK_DIR/manifest-unreachable-http.yaml" <<EOF
endpoints:
  - url: "http://127.0.0.1:${UNUSED_PORT}/"
    expected_status: 200
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest-unreachable-http.yaml")"; code=$?
assert_exit "1" "$code" "manifest with unreachable endpoint exits 1"
assert_contains "$out" "no response or timeout" "unreachable endpoint is reported cleanly"
if [[ "$out" == *"000000"* ]]; then
  printf '  FAIL  %s\n' "unreachable endpoint does not mangle the status code into 000000"; ((FAIL++))
else
  printf '  PASS  %s\n' "unreachable endpoint does not mangle the status code into 000000"; ((PASS++))
fi

# ============================================================================
# Scenario 6: multiple simultaneous failures reported together (default mode)
# ============================================================================
cat > "$WORK_DIR/manifest-multi-fail.yaml" <<EOF
files:
  - path: ${WORK_DIR}/app/does-not-exist-1.conf
  - path: ${WORK_DIR}/app/does-not-exist-2.conf
services:
  - definitely-not-a-real-service-$$
EOF

out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml")"; code=$?
assert_exit "1" "$code" "manifest with multiple failures exits 1"
assert_contains "$out" "items checked : 3" "multi-failure run still checks every item (default mode)"
assert_contains "$out" "fail          : 3" "multi-failure run counts all 3 failures"
fail_count=$(grep -c '^  - ' <<< "$out")
assert_exit "3" "$fail_count" "multi-failure run lists all 3 failures in the summary"

# ============================================================================
# Scenario 7: --strict stops at the first failure
# ============================================================================
out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml" --strict)"; code=$?
assert_exit "1" "$code" "--strict still exits 1 on failure"
assert_contains "$out" "stopping on first failure" "--strict announces early stop"
assert_contains "$out" "items checked : 1" "--strict stops after the first item, not all 3"

# ============================================================================
# Scenario 8: --json output is well-formed and matches text-mode counts
# ============================================================================
json_out="$("$BIN" --manifest "$WORK_DIR/manifest-multi-fail.yaml" --json)"; code=$?
assert_exit "1" "$code" "--json still exits 1 on failure"
assert_contains "$json_out" '"items_total": 3' "--json reports correct items_total"
assert_contains "$json_out" '"items_fail": 3' "--json reports correct items_fail"
assert_contains "$json_out" '"overall": "FAIL"' "--json reports overall FAIL"
if command -v jq >/dev/null 2>&1; then
  if echo "$json_out" | jq -e . >/dev/null 2>&1; then
    printf '  PASS  %s\n' "--json output is valid JSON (parsed with jq)"; ((PASS++))
  else
    printf '  FAIL  %s\n' "--json output is not valid JSON"; ((FAIL++))
  fi
fi

# ============================================================================
# Scenario 9: JSON-format manifest (not just YAML) is accepted
# ============================================================================
cat > "$WORK_DIR/manifest.json" <<EOF
{
  "files": [
    { "path": "${WORK_DIR}/app/webapps/app.war", "version": "3.4.0" }
  ],
  "services": ["${FIXTURE_MARKER}"]
}
EOF
out="$("$BIN" --manifest "$WORK_DIR/manifest.json")"; code=$?
assert_exit "0" "$code" "JSON-format manifest is parsed and passes"

# ============================================================================
# Scenario 10: usage errors
# ============================================================================
"$BIN" --manifest /no/such/manifest.yaml >/dev/null 2>&1; code=$?
assert_exit "2" "$code" "nonexistent manifest path exits 2"

"$BIN" >/dev/null 2>&1; code=$?
assert_exit "2" "$code" "missing --manifest argument exits 2"

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
