#!/usr/bin/env bash
# apache.sh - a constrained Apache httpd.conf reader.
#
# Not a general Apache config parser: it understands top-level
# directives (ServerTokens, ServerSignature, Timeout) and single-level
# <Location>/<Directory> blocks matched by canonical Apache case (as
# virtually every real config is written -- Apache directives are
# case-insensitive, but nobody actually writes `SERVERTOKENS` by hand).
# macOS's /usr/bin/awk is the classic "one true awk", which has no
# IGNORECASE (a gawk-only extension) -- matching canonical case avoids
# that gap entirely rather than silently mis-parsing on macOS.

# apache_get_directive <file> <directive>
# Last matching top-level occurrence, value only. Apache directives are
# generally last-wins when repeated, which this mirrors.
apache_get_directive() {
  local file="$1" directive="$2"
  grep -E "^[[:space:]]*${directive}[[:space:]]+" "$file" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*[A-Za-z]+[[:space:]]+//' \
    | tr -d '"' \
    | xargs
}

# apache_get_block <file> <tag> <needle>
# Body (exclusive) of the first <tag ...needle...> ... </tag> block
# whose opening line contains `needle` (e.g. a path). Single-level only:
# does not handle nested blocks of the same tag.
apache_get_block() {
  local file="$1" tag="$2" needle="$3"
  # `closetag`, not `close`: `close()` is an awk builtin function, and
  # BWK awk (macOS's /usr/bin/awk) rejects a variable that shadows it
  # with a syntax error -- gawk is more forgiving, which is exactly the
  # kind of thing that passes on Linux and breaks on a Mac.
  awk -v tag="<${tag}" -v closetag="</${tag}>" -v needle="$needle" '
    BEGIN { in_block = 0 }
    {
      if (!in_block && index($0, tag) > 0 && index($0, needle) > 0) { in_block = 1; next }
      if (in_block && index($0, closetag) > 0) { in_block = 0; next }
      if (in_block) print
    }
  ' "$file"
}

# --- ServerTokens / ServerSignature -----------------------------------------
# Both leak version information if left permissive. Apache's own
# documented defaults differ when the directive is absent entirely:
# ServerTokens defaults to "Full" (the most revealing setting);
# ServerSignature defaults to "Off". Getting this backwards would make
# an absent ServerTokens directive look safe when it's actually the
# worst case.
check_server_tokens() {
  local file="$1" expected="$2"
  local actual
  actual="$(apache_get_directive "$file" ServerTokens)"
  [[ -z "$actual" ]] && actual="Full"   # Apache's documented default when unset

  if [[ "$(_lc "$actual")" == "$(_lc "$expected")" ]]; then
    report "PASS" "apache:ServerTokens" "set to '${actual}' as expected"
  else
    report "FAIL" "apache:ServerTokens" "set to '${actual}', policy expects '${expected}'"
  fi
}

check_server_signature() {
  local file="$1" expected="$2"
  local actual
  actual="$(apache_get_directive "$file" ServerSignature)"
  [[ -z "$actual" ]] && actual="Off"    # Apache's documented default when unset

  if [[ "$(_lc "$actual")" == "$(_lc "$expected")" ]]; then
    report "PASS" "apache:ServerSignature" "set to '${actual}' as expected"
  else
    report "FAIL" "apache:ServerSignature" "set to '${actual}', policy expects '${expected}'"
  fi
}

# --- Timeout -----------------------------------------------------------
check_timeout() {
  local file="$1" max_seconds="$2"
  local actual
  actual="$(apache_get_directive "$file" Timeout)"
  [[ -z "$actual" ]] && actual="60"     # Apache 2.4's documented default when unset

  if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual <= max_seconds )); then
    report "PASS" "apache:Timeout" "${actual}s (policy max ${max_seconds}s)"
  else
    report "FAIL" "apache:Timeout" "${actual}s exceeds policy max of ${max_seconds}s"
  fi
}

# --- server-status / server-info exposure -----------------------------
# If the Location block isn't present at all, the handler was never
# turned on (SetHandler is what actually enables it), so absence is
# treated as "not exposed," not as a finding.
_check_handler_restricted() {
  local file="$1" path="$2" label="$3"
  local block
  block="$(apache_get_block "$file" "Location" "$path")"

  if [[ -z "$block" ]]; then
    report "PASS" "apache:${label}" "no <Location \"${path}\"> block configured, handler not enabled"
    return
  fi

  if grep -qE '^[[:space:]]*Require[[:space:]]' <<< "$block"; then
    local rule; rule="$(grep -E '^[[:space:]]*Require[[:space:]]' <<< "$block" | tail -1 | xargs)"
    report "PASS" "apache:${label}" "restricted (${rule})"
  elif grep -qE '^[[:space:]]*(Order|Allow|Deny)[[:space:]]' <<< "$block"; then
    # Apache 2.2-style access control. Recognized as "something is here"
    # rather than parsed for correctness -- Order/Allow/Deny's merge
    # rules are their own can of worms, so this is flagged for a human
    # to actually read rather than confidently graded as PASS or FAIL.
    report "WARN" "apache:${label}" "uses old-style Order/Allow/Deny -- verify manually, not evaluated by this tool"
  else
    report "FAIL" "apache:${label}" "<Location \"${path}\"> has no Require directive -- exposed with no access restriction"
  fi
}

check_server_status() { _check_handler_restricted "$1" "/server-status" "server-status"; }
check_server_info()   { _check_handler_restricted "$1" "/server-info" "server-info"; }

# --- Directory listing --------------------------------------------------
# Simplified relative to Apache's real Options-merging rules (a bare
# "Options Indexes" replaces inherited options entirely, while
# "+Indexes"/"-Indexes" merge with the parent context) -- this checks
# only the matched block's own Options line for a bare or "+"-prefixed
# "Indexes", which covers the common cases without re-implementing
# Apache's full context-inheritance semantics.
check_directory_listing() {
  local file="$1" path="$2"
  local block options

  block="$(apache_get_block "$file" "Directory" "$path")"
  if [[ -z "$block" ]]; then
    report "WARN" "apache:directory_listing:${path}" "no <Directory \"${path}\"> block found -- cannot confirm indexing is disabled, verify manually"
    return
  fi

  options="$(grep -E '^[[:space:]]*Options[[:space:]]' <<< "$block" | tail -1)"
  if [[ -z "$options" ]]; then
    report "WARN" "apache:directory_listing:${path}" "no Options directive in <Directory \"${path}\"> -- cannot confirm indexing is disabled, verify manually"
  elif grep -qE '(^|[[:space:]])(\+)?Indexes([[:space:]]|$)' <<< "$options"; then
    report "FAIL" "apache:directory_listing:${path}" "Options includes Indexes -- directory listing is enabled"
  else
    report "PASS" "apache:directory_listing:${path}" "directory listing disabled"
  fi
}
