#!/usr/bin/env bash
# run-tests.sh - runs the real bin/webserver-config-audit against a fully
# compliant baseline (copied from conf/example-*) and against several
# copies each with exactly one deviation, asserting each is caught.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/bin/webserver-config-audit"
POLICY="${ROOT_DIR}/conf/policy.yaml"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

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

cp "${ROOT_DIR}/conf/example-httpd.conf" "$WORK_DIR/httpd.conf"
cp "${ROOT_DIR}/conf/example-server.xml" "$WORK_DIR/server.xml"

# Real Tomcat-style layout so the default-apps check has a genuine
# directory tree to look at, not just the standalone example.
mkdir -p "$WORK_DIR/tomcat/conf" "$WORK_DIR/tomcat/webapps/ROOT"
cp "${ROOT_DIR}/conf/example-server.xml" "$WORK_DIR/tomcat/conf/server.xml"

# =============================================================================
# Scenario 1: fully-compliant configs
# =============================================================================
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd.conf" --server-xml "$WORK_DIR/server.xml" --webapps-dir "$WORK_DIR/tomcat/webapps")"; code=$?
assert_exit "0" "$code" "fully-compliant configs: OVERALL PASS (exit 0)"
assert_contains "$out" "OVERALL: PASS" "fully-compliant configs report OVERALL: PASS"
assert_contains "$out" "fail          : 0" "fully-compliant configs have zero failures"
assert_contains "$out" "warn          : 0" "fully-compliant configs have zero warnings (real webapps dir given)"

# =============================================================================
# Scenario 2: Apache deviations, one at a time
# =============================================================================
sed 's/ServerTokens Prod/ServerTokens Full/' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-tokens.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-tokens.conf")"; code=$?
assert_exit "2" "$code" "ServerTokens Full: OVERALL FAIL (exit 2)"
assert_contains "$out" "set to 'Full', policy expects 'Prod'" "ServerTokens deviation names actual vs expected"

sed 's/ServerSignature Off/ServerSignature On/' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-sig.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-sig.conf")"; code=$?
assert_exit "2" "$code" "ServerSignature On: OVERALL FAIL"
assert_contains "$out" "set to 'On', policy expects 'Off'" "ServerSignature deviation names actual vs expected"

sed 's/Timeout 60/Timeout 300/' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-timeout.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-timeout.conf")"; code=$?
assert_exit "2" "$code" "Timeout 300 exceeds policy max: OVERALL FAIL"
assert_contains "$out" "300s exceeds policy max of 60s" "Timeout deviation names actual vs expected"

# Remove the Require line from the server-status block -- wide open.
awk '/SetHandler server-status/{print; getline; next} {print}' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-status.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-status.conf")"; code=$?
assert_exit "2" "$code" "server-status with no Require: OVERALL FAIL"
assert_contains "$out" "exposed with no access restriction" "unrestricted server-status is caught"

sed 's/Options -Indexes -Includes/Options Indexes -Includes/' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-indexes.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-indexes.conf")"; code=$?
assert_exit "2" "$code" "Options Indexes enabled: OVERALL FAIL"
assert_contains "$out" "directory listing is enabled" "enabled directory listing is caught"

# Old-style access control -- WARN, not FAIL or a silent PASS.
sed '/Require local/{s//Order deny,allow\n    Allow from 127.0.0.1/}' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-oldstyle.conf" 2>/dev/null \
  || perl -pe 's/Require local/Order deny,allow\n    Allow from 127.0.0.1/' "$WORK_DIR/httpd.conf" > "$WORK_DIR/httpd-oldstyle.conf"
out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-oldstyle.conf")"; code=$?
assert_exit "1" "$code" "old-style Order/Allow/Deny: OVERALL WARN (exit 1), not FAIL"
assert_contains "$out" "verify manually, not evaluated by this tool" "old-style access control is flagged for manual review"

# =============================================================================
# Scenario 3: Tomcat deviations, one at a time
# =============================================================================
# `0,/regex/{...}` (GNU sed's "range starting before line 1" idiom for
# "replace only the first match in the whole file") has no BSD/macOS sed
# equivalent -- BSD sed doesn't support that address form at all. `perl`
# ships on macOS and Linux alike, and this one-liner replaces only the
# first match across the whole file regardless of sed flavor.
# Brace delimiters, not `/`: several of the strings being replaced
# contain a literal "/" (e.g. protocol="HTTP/1.1"), which would otherwise
# have to be escaped and is easy to get wrong across a shell-quoting and
# a regex-escaping layer at once -- braces need no escaping for "/" at
# all, only for a literal "." if exact matching matters.
first_match_only() {
  perl -pe '$done or s{'"$1"'}{'"$2"'} and $done=1' "$3"
}

first_match_only 'maxThreads="200"' 'maxThreads="50"' "$WORK_DIR/server.xml" > "$WORK_DIR/server-threads.xml"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server-threads.xml")"; code=$?
assert_exit "2" "$code" "maxThreads below policy minimum: OVERALL FAIL"
assert_contains "$out" "50 is below policy minimum of 150" "low maxThreads is caught"

sed 's/connectionTimeout="20000"/connectionTimeout="60000"/' "$WORK_DIR/server.xml" > "$WORK_DIR/server-timeout.xml"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server-timeout.xml")"; code=$?
assert_exit "2" "$code" "connectionTimeout above policy max: OVERALL FAIL"
assert_contains "$out" "60000ms exceeds policy max of 20000ms" "high connectionTimeout is caught"

first_match_only 'protocol="HTTP/1\.1"' 'protocol="AJP/1.3"' "$WORK_DIR/server.xml" > "$WORK_DIR/server-protocol.xml"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server-protocol.xml")"; code=$?
assert_exit "2" "$code" "wrong protocol on the policy port: OVERALL FAIL"
assert_contains "$out" "protocol is 'AJP/1.3', policy expects 'HTTP/1.1'" "wrong protocol names actual vs expected"

first_match_only 'protocols="TLSv1\.2,TLSv1\.3"' 'protocols="TLSv1.1,TLSv1.2"' "$WORK_DIR/server.xml" > "$WORK_DIR/server-ssl.xml"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server-ssl.xml")"; code=$?
assert_exit "2" "$code" "SSL protocols include a deprecated one: OVERALL FAIL"
assert_contains "$out" "include a deprecated protocol" "deprecated SSL protocol is caught"

# No Connector at all on the policy's expected port.
sed 's/port="8080"/port="9090"/' "$WORK_DIR/server.xml" > "$WORK_DIR/server-noport.xml"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server-noport.xml")"; code=$?
assert_exit "2" "$code" "no connector on the policy port: OVERALL FAIL"
assert_contains "$out" "no <Connector port=\"8080\"> found" "missing connector on the policy port is caught"

# Default apps present.
mkdir -p "$WORK_DIR/tomcat/webapps/manager"
out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server.xml" --webapps-dir "$WORK_DIR/tomcat/webapps")"; code=$?
assert_exit "2" "$code" "manager webapp still deployed: OVERALL FAIL"
assert_contains "$out" "still deployed at" "deployed manager app is caught"
rmdir "$WORK_DIR/tomcat/webapps/manager"

out="$("$BIN" --policy "$POLICY" --server-xml "$WORK_DIR/server.xml" --webapps-dir "$WORK_DIR/no-such-dir")"; code=$?
assert_exit "1" "$code" "webapps dir cannot be found: OVERALL WARN (exit 1), not a silent PASS or FAIL"
assert_contains "$out" "cannot verify" "unverifiable default-apps check is flagged, not guessed"

# =============================================================================
# Scenario 4: usage and JSON
# =============================================================================
"$BIN" --policy "$POLICY" >/dev/null 2>&1; code=$?
assert_exit "3" "$code" "neither --httpd-conf nor --server-xml given: usage error (exit 3)"

"$BIN" --httpd-conf "$WORK_DIR/httpd.conf" >/dev/null 2>&1; code=$?
assert_exit "3" "$code" "missing --policy: usage error (exit 3)"

"$BIN" --policy /no/such/policy.yaml --httpd-conf "$WORK_DIR/httpd.conf" >/dev/null 2>&1; code=$?
assert_exit "3" "$code" "nonexistent policy file: usage error (exit 3)"

json_out="$("$BIN" --policy "$POLICY" --httpd-conf "$WORK_DIR/httpd-tokens.conf" --json)"; code=$?
assert_exit "2" "$code" "--json still exits 2 on a real FAIL"
assert_contains "$json_out" '"items_fail"' "--json includes items_fail"
assert_contains "$json_out" '"status": "FAIL"' "--json findings include the FAIL status"
if command -v jq >/dev/null 2>&1; then
  if echo "$json_out" | jq -e . >/dev/null 2>&1; then
    printf '  PASS  %s\n' "--json output is valid JSON (parsed with jq)"; ((PASS++))
  else
    printf '  FAIL  %s\n' "--json output is not valid JSON"; ((FAIL++))
  fi
fi

"$BIN" --help >/dev/null 2>&1; code=$?
assert_exit "0" "$code" "--help exits 0"

echo
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
