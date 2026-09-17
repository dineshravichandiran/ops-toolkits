#!/usr/bin/env bash
# policy.sh - reads policy.yaml into shell variables.
#
# Fixed schema, not a general YAML parser -- same philosophy as
# deploy-validator's and upgrade-preflight's manifest readers. The
# policy has a known, small set of keys; this reads exactly those.

# _policy_scalar <file> <key>
policy_scalar() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*${key}:[[:space:]]*" "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^:]+:[[:space:]]*//' \
    | tr -d '"' \
    | xargs
}

# _policy_list <file> <header-key>
# Lines "  - value" immediately following "header-key:", up to the next
# line that isn't a list item.
policy_list() {
  local file="$1" header="$2"
  awk -v header="${header}:" '
    BEGIN { in_list = 0 }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == header) { in_list = 1; next }
      if (in_list) {
        if (line ~ /^-[[:space:]]*/) {
          val = line
          sub(/^-[[:space:]]*/, "", val)
          print val
        } else {
          in_list = 0
        }
      }
    }
  ' "$file" | tr -d '"' | while read -r v; do printf '%s\n' "$(xargs <<< "$v")"; done
}

load_policy() {
  local file="$1"
  [[ -f "$file" ]] || die "policy file not found: $file"

  POLICY_APACHE_SERVER_TOKENS="$(policy_scalar "$file" server_tokens)"
  POLICY_APACHE_SERVER_SIGNATURE="$(policy_scalar "$file" server_signature)"
  POLICY_APACHE_TIMEOUT_MAX_SECONDS="$(policy_scalar "$file" timeout_max_seconds)"
  POLICY_APACHE_RESTRICT_SERVER_STATUS="$(policy_scalar "$file" restrict_server_status)"
  POLICY_APACHE_RESTRICT_SERVER_INFO="$(policy_scalar "$file" restrict_server_info)"

  POLICY_TOMCAT_PORT="$(policy_scalar "$file" port)"
  POLICY_TOMCAT_PROTOCOL="$(policy_scalar "$file" protocol)"
  POLICY_TOMCAT_MIN_MAX_THREADS="$(policy_scalar "$file" min_max_threads)"
  POLICY_TOMCAT_MAX_CONN_TIMEOUT_MS="$(policy_scalar "$file" max_connection_timeout_ms)"
  POLICY_TOMCAT_SSL_MIN_PROTOCOL="$(policy_scalar "$file" min_protocol)"

  POLICY_DIR_LISTING_DISABLED=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && POLICY_DIR_LISTING_DISABLED+=("$line")
  done < <(policy_list "$file" directory_listing_disabled)

  POLICY_DEFAULT_APPS_ABSENT=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && POLICY_DEFAULT_APPS_ABSENT+=("$line")
  done < <(policy_list "$file" default_apps_must_be_absent)
}
