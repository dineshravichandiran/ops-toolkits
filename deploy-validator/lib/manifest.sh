#!/usr/bin/env bash
# manifest.sh - parses the deployment manifest.
#
# Supports two formats, auto-detected by extension (.json / .yml|.yaml):
#   - JSON, parsed with jq if available.
#   - A constrained YAML subset, parsed with a small line-based parser that
#     needs no external YAML library. This is not a general YAML parser; it
#     understands exactly the shape documented in README.md and in
#     conf/example-manifest.yaml.
#
# Either format is normalised into the same set of bash arrays so the check
# functions in checks.sh never need to know which format was used:
#   MANIFEST_FILES        (path)
#   MANIFEST_FILE_VERSIONS (path|version-or-empty)
#   MANIFEST_VERSION_CHECKS (path|pattern)
#   MANIFEST_SERVICES      (name)
#   MANIFEST_ENDPOINTS     (url|expected_code)

MANIFEST_FILES=()
MANIFEST_FILE_VERSIONS=()
MANIFEST_VERSION_CHECKS=()
MANIFEST_SERVICES=()
MANIFEST_ENDPOINTS=()

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Strip matching single or double quotes from a scalar value.
_unquote() {
  local s="$1"
  if [[ "$s" =~ ^\"(.*)\"$ ]] || [[ "$s" =~ ^\'(.*)\'$ ]]; then
    s="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$s"
}

load_manifest_json() {
  local file="$1"
  command -v jq >/dev/null 2>&1 || die "manifest is JSON but jq is not installed"

  jq -e . "$file" >/dev/null 2>&1 || die "manifest is not valid JSON: $file"

  local n i
  n=$(jq '.files // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local path version
    path=$(jq -r ".files[$i].path" "$file")
    version=$(jq -r ".files[$i].version // empty" "$file" 2>/dev/null)
    [[ -z "$path" || "$path" == "null" ]] && continue
    MANIFEST_FILES+=("$path")
    MANIFEST_FILE_VERSIONS+=("${path}|${version}")
  done

  n=$(jq '.version_checks // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local path pattern
    path=$(jq -r ".version_checks[$i].path" "$file")
    pattern=$(jq -r ".version_checks[$i].pattern" "$file")
    [[ -z "$path" || "$path" == "null" ]] && continue
    MANIFEST_VERSION_CHECKS+=("${path}|${pattern}")
  done

  n=$(jq '.services // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local svc
    svc=$(jq -r ".services[$i]" "$file")
    [[ -z "$svc" || "$svc" == "null" ]] && continue
    MANIFEST_SERVICES+=("$svc")
  done

  n=$(jq '.endpoints // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local url code
    url=$(jq -r ".endpoints[$i].url" "$file")
    code=$(jq -r ".endpoints[$i].expected_status // 200" "$file")
    [[ -z "$url" || "$url" == "null" ]] && continue
    MANIFEST_ENDPOINTS+=("${url}|${code}")
  done
}

# Line-based parser for the constrained YAML subset. State machine tracks
# which top-level list ("files:", "version_checks:", "services:",
# "endpoints:") we're inside, and accumulates key: value pairs of the
# current list item until the next "- " starts a new one.
load_manifest_yaml() {
  local file="$1"
  local section="" cur_path="" cur_version="" cur_pattern="" cur_url="" cur_code=""

  flush_files() {
    [[ -n "$cur_path" ]] && { MANIFEST_FILES+=("$cur_path"); MANIFEST_FILE_VERSIONS+=("${cur_path}|${cur_version}"); }
    cur_path=""; cur_version=""
  }
  flush_version_checks() {
    [[ -n "$cur_path" ]] && MANIFEST_VERSION_CHECKS+=("${cur_path}|${cur_pattern}")
    cur_path=""; cur_pattern=""
  }
  flush_endpoints() {
    [[ -n "$cur_url" ]] && MANIFEST_ENDPOINTS+=("${cur_url}|${cur_code:-200}")
    cur_url=""; cur_code=""
  }

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    # strip comments (naive: a '#' preceded by whitespace or at line start,
    # not inside quotes -- sufficient for this manifest's simple values)
    local line="$raw_line"
    line="${line%%#*}"
    [[ -z "$(_trim "$line")" ]] && continue

    # top-level section headers, e.g. "files:"
    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*$ ]]; then
      case "$section" in
        files)          flush_files ;;
        version_checks) flush_version_checks ;;
        endpoints)      flush_endpoints ;;
      esac
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # new list item: "  - key: value" or "  - value" (services is a flat list)
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
      local rest; rest="${BASH_REMATCH[1]}"
      case "$section" in
        files)          flush_files ;;
        version_checks) flush_version_checks ;;
        endpoints)      flush_endpoints ;;
      esac

      if [[ "$section" == "services" ]]; then
        [[ -n "$(_trim "$rest")" ]] && MANIFEST_SERVICES+=("$(_unquote "$(_trim "$rest")")")
        continue
      fi

      # "- key: value" on the same line as the dash
      if [[ "$rest" =~ ^([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
        local k="${BASH_REMATCH[1]}" v; v="$(_unquote "$(_trim "${BASH_REMATCH[2]}")")"
        case "$section:$k" in
          files:path)             cur_path="$v" ;;
          files:version)          cur_version="$v" ;;
          version_checks:path)    cur_path="$v" ;;
          version_checks:pattern) cur_pattern="$v" ;;
          endpoints:url)          cur_url="$v" ;;
          endpoints:expected_status) cur_code="$v" ;;
        esac
      fi
      continue
    fi

    # continuation "key: value" line for the current list item
    if [[ "$line" =~ ^[[:space:]]+([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v; v="$(_unquote "$(_trim "${BASH_REMATCH[2]}")")"
      case "$section:$k" in
        files:path)             cur_path="$v" ;;
        files:version)          cur_version="$v" ;;
        version_checks:path)    cur_path="$v" ;;
        version_checks:pattern) cur_pattern="$v" ;;
        endpoints:url)          cur_url="$v" ;;
        endpoints:expected_status) cur_code="$v" ;;
      esac
      continue
    fi
  done < "$file"

  case "$section" in
    files)          flush_files ;;
    version_checks) flush_version_checks ;;
    endpoints)      flush_endpoints ;;
  esac
}

load_manifest() {
  local file="$1"
  [[ -f "$file" ]] || die "manifest not found: $file"

  case "$file" in
    *.json)        load_manifest_json "$file" ;;
    *.yml|*.yaml)  load_manifest_yaml "$file" ;;
    *)
      # sniff: JSON manifests start with '{' after whitespace
      if [[ "$(head -c1 <(_trim "$(cat "$file")"))" == "{" ]]; then
        load_manifest_json "$file"
      else
        load_manifest_yaml "$file"
      fi
      ;;
  esac

  local total=$(( ${#MANIFEST_FILES[@]} + ${#MANIFEST_VERSION_CHECKS[@]} + ${#MANIFEST_SERVICES[@]} + ${#MANIFEST_ENDPOINTS[@]} ))
  (( total > 0 )) || die "manifest has no checkable items (files/version_checks/services/endpoints all empty): $file"
}
