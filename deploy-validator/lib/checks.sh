#!/usr/bin/env bash
# checks.sh - runs the checks described by a loaded manifest.
# Each function reports through report() from common.sh. Read-only: nothing
# here ever writes, deletes, or restarts anything.

# ---------------------------------------------------------------------------
# Expected files exist.
# ---------------------------------------------------------------------------
check_files_exist() {
  local i
  for i in "${!MANIFEST_FILES[@]}"; do
    local path="${MANIFEST_FILES[$i]}"
    if [[ -e "$path" ]]; then
      report "PASS" "file:${path}" "present"
    else
      report "FAIL" "file:${path}" "expected file not found"
    fi
  done
}

# ---------------------------------------------------------------------------
# Expected version string appears in the file's contents (a simple grep).
# Entries come from either files[].version (checked against the same file
# the existence check covers) or the separate version_checks[] list, which
# lets a manifest check a version string in a file it doesn't otherwise
# care about the mere existence of (e.g. a version stamped inside a larger
# config file).
# ---------------------------------------------------------------------------
check_versions() {
  local entry path version
  # Guard each loop with a length check rather than expanding "${ARR[@]}"
  # unconditionally: bash 3.2 (macOS's shipped /bin/bash) treats expanding
  # an empty array under `set -u` as an unbound variable in some contexts,
  # a quirk fixed only in bash 4.4+. Falling back to "${ARR[@]:-}" is not a
  # reliable substitute either -- inside a function, bash 3.2 expands that
  # to a single empty-string element instead of zero, which would call
  # _check_one_version with a blank path. The either-array caller guard in
  # run_all_checks means check_versions can be entered with just one of
  # these two arrays populated, so both loops need their own guard.
  if (( ${#MANIFEST_FILE_VERSIONS[@]} )); then
    for entry in "${MANIFEST_FILE_VERSIONS[@]}"; do
      path="${entry%%|*}"
      version="${entry#*|}"
      [[ -z "$version" ]] && continue   # no version expected for this file
      _check_one_version "$path" "$version"
    done
  fi

  if (( ${#MANIFEST_VERSION_CHECKS[@]} )); then
    for entry in "${MANIFEST_VERSION_CHECKS[@]}"; do
      path="${entry%%|*}"
      version="${entry#*|}"
      _check_one_version "$path" "$version"
    done
  fi
}

_check_one_version() {
  local path="$1" pattern="$2"

  if [[ ! -e "$path" ]]; then
    report "FAIL" "version:${path}" "cannot check version, file not found"
    return
  fi

  if grep -q -- "$pattern" "$path" 2>/dev/null; then
    report "PASS" "version:${path}" "found expected string '${pattern}'"
  else
    report "FAIL" "version:${path}" "expected string '${pattern}' not found"
  fi
}

# ---------------------------------------------------------------------------
# Expected services are running. Same systemd-first, process-table-fallback
# approach as the pre-flight/health-check tools, so behavior is consistent
# across the toolkit on hosts with and without systemd.
# ---------------------------------------------------------------------------
check_services() {
  local svc
  for svc in "${MANIFEST_SERVICES[@]}"; do
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
      if systemctl is-active --quiet "$svc"; then
        report "PASS" "service:${svc}" "active (systemd)"
      else
        report "FAIL" "service:${svc}" "inactive (systemd)"
      fi
      continue
    fi

    # Exclude this script's own PID (and its parent shell) from the match.
    # pgrep -f matches against the full command line, so without this a
    # service name that happens to appear in how the check itself was
    # invoked (e.g. inside a wrapper script's command line, or a build
    # directory path) can match this process rather than the real one.
    local hits
    hits=$(pgrep -f "$svc" 2>/dev/null | grep -v -x -e "$$" -e "$PPID" || true)
    if [[ -n "$hits" ]]; then
      report "PASS" "service:${svc}" "process running"
    else
      report "FAIL" "service:${svc}" "not running (checked systemd and process table)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Expected HTTP endpoints return the expected status code.
# ---------------------------------------------------------------------------
check_endpoints() {
  local entry url expect
  for entry in "${MANIFEST_ENDPOINTS[@]}"; do
    url="${entry%%|*}"
    expect="${entry#*|}"

    command -v curl >/dev/null 2>&1 || {
      report "FAIL" "http:${url}" "curl not available, cannot check"; continue; }

    # curl writes "000" via -w AND exits non-zero on a connection failure
    # (refused, timed out, unresolvable host). Capturing with
    # `curl ... || echo "000"` double-counts that case: curl's own "000"
    # lands in the substitution, then the || fallback appends a second
    # "000" on top of it, producing "000000". Capture unconditionally and
    # ignore curl's exit status entirely -- the %{http_code} value alone
    # (with "000" as its own explicit not-connected case, handled below)
    # is a complete and correct signal on its own.
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${HTTP_TIMEOUT:-10}" "$url" 2>/dev/null)
    [[ -z "$code" ]] && code="000"

    if [[ "$code" == "$expect" ]]; then
      report "PASS" "http:${url}" "HTTP ${code} as expected"
    elif [[ "$code" == "000" ]]; then
      report "FAIL" "http:${url}" "no response or timeout"
    else
      report "FAIL" "http:${url}" "HTTP ${code}, expected ${expect}"
    fi
  done
}

run_all_checks() {
  section "Files"
  if (( ${#MANIFEST_FILES[@]} > 0 )); then
    check_files_exist
  else
    printf '  (none in manifest)\n'
  fi

  section "Versions"
  if (( ${#MANIFEST_FILE_VERSIONS[@]} > 0 || ${#MANIFEST_VERSION_CHECKS[@]} > 0 )); then
    check_versions
  else
    printf '  (none in manifest)\n'
  fi

  section "Services"
  if (( ${#MANIFEST_SERVICES[@]} > 0 )); then
    check_services
  else
    printf '  (none in manifest)\n'
  fi

  section "HTTP endpoints"
  if (( ${#MANIFEST_ENDPOINTS[@]} > 0 )); then
    check_endpoints
  else
    printf '  (none in manifest)\n'
  fi
}
