#!/usr/bin/env bash
# manifest.sh - parses the preflight manifest.
#
# Same shape as deploy-validator/lib/manifest.sh on purpose: two formats
# auto-detected by extension (.json parsed with jq, .yml/.yaml parsed with
# a small purpose-built line reader), normalised into bash arrays so
# checks.sh never needs to know which format was used. All five sections
# are lists -- including the ones that conceptually have "one" backup or
# "one" version check -- so every section uses the exact same list
# parsing logic instead of a special case for scalars.
#
#   PREFLIGHT_DISK_SPACE   (path|min_free_mb)
#   PREFLIGHT_BACKUPS      (path|max_age_hours)
#   PREFLIGHT_VERSIONS     (source|target|pattern)   source: file|command
#   PREFLIGHT_SERVICES     (name|expected_state)      expected_state: running|stopped
#   PREFLIGHT_ZOMBIE_PATTERNS (pattern)

PREFLIGHT_DISK_SPACE=()
PREFLIGHT_BACKUPS=()
PREFLIGHT_VERSIONS=()
PREFLIGHT_SERVICES=()
PREFLIGHT_ZOMBIE_PATTERNS=()

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

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
  n=$(jq '.disk_space // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local path min
    path=$(jq -r ".disk_space[$i].path" "$file")
    min=$(jq -r ".disk_space[$i].min_free_mb" "$file")
    [[ -z "$path" || "$path" == "null" ]] && continue
    PREFLIGHT_DISK_SPACE+=("${path}|${min}")
  done

  n=$(jq '.backups // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local path max_age
    path=$(jq -r ".backups[$i].path" "$file")
    max_age=$(jq -r ".backups[$i].max_age_hours" "$file")
    [[ -z "$path" || "$path" == "null" ]] && continue
    PREFLIGHT_BACKUPS+=("${path}|${max_age}")
  done

  n=$(jq '.versions // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local source target pattern
    source=$(jq -r ".versions[$i].source" "$file")
    target=$(jq -r ".versions[$i].path // .versions[$i].command // empty" "$file")
    pattern=$(jq -r ".versions[$i].pattern // empty" "$file")
    [[ -z "$source" || "$source" == "null" ]] && continue
    PREFLIGHT_VERSIONS+=("${source}|${target}|${pattern}")
  done

  n=$(jq '.services // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local name state
    name=$(jq -r ".services[$i].name" "$file")
    state=$(jq -r ".services[$i].expected_state // \"running\"" "$file")
    [[ -z "$name" || "$name" == "null" ]] && continue
    PREFLIGHT_SERVICES+=("${name}|${state}")
  done

  n=$(jq '.zombie_patterns // [] | length' "$file")
  for ((i=0; i<n; i++)); do
    local pattern
    pattern=$(jq -r ".zombie_patterns[$i]" "$file")
    [[ -z "$pattern" || "$pattern" == "null" ]] && continue
    PREFLIGHT_ZOMBIE_PATTERNS+=("$pattern")
  done
}

# Line-based parser for the constrained YAML subset. State machine tracks
# which top-level list we're inside, and accumulates key: value pairs of
# the current list item until the next "- " starts a new one.
load_manifest_yaml() {
  local file="$1"
  local section=""
  local cur_path="" cur_min="" cur_max_age="" cur_source="" cur_target="" cur_pattern="" cur_name="" cur_state=""

  flush_disk_space() {
    [[ -n "$cur_path" ]] && PREFLIGHT_DISK_SPACE+=("${cur_path}|${cur_min}")
    cur_path=""; cur_min=""
  }
  flush_backups() {
    [[ -n "$cur_path" ]] && PREFLIGHT_BACKUPS+=("${cur_path}|${cur_max_age}")
    cur_path=""; cur_max_age=""
  }
  flush_versions() {
    [[ -n "$cur_source" ]] && PREFLIGHT_VERSIONS+=("${cur_source}|${cur_target}|${cur_pattern}")
    cur_source=""; cur_target=""; cur_pattern=""
  }
  flush_services() {
    [[ -n "$cur_name" ]] && PREFLIGHT_SERVICES+=("${cur_name}|${cur_state:-running}")
    cur_name=""; cur_state=""
  }
  flush_current_section() {
    case "$section" in
      disk_space) flush_disk_space ;;
      backups)    flush_backups ;;
      versions)   flush_versions ;;
      services)   flush_services ;;
    esac
  }

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="$raw_line"
    line="${line%%#*}"
    [[ -z "$(_trim "$line")" ]] && continue

    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*$ ]]; then
      flush_current_section
      section="${BASH_REMATCH[1]}"
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
      local rest; rest="${BASH_REMATCH[1]}"
      flush_current_section

      if [[ "$section" == "zombie_patterns" ]]; then
        [[ -n "$(_trim "$rest")" ]] && PREFLIGHT_ZOMBIE_PATTERNS+=("$(_unquote "$(_trim "$rest")")")
        continue
      fi

      if [[ "$rest" =~ ^([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
        local k="${BASH_REMATCH[1]}" v; v="$(_unquote "$(_trim "${BASH_REMATCH[2]}")")"
        case "$section:$k" in
          disk_space:path)     cur_path="$v" ;;
          disk_space:min_free_mb) cur_min="$v" ;;
          backups:path)         cur_path="$v" ;;
          backups:max_age_hours) cur_max_age="$v" ;;
          versions:source)      cur_source="$v" ;;
          versions:path)        cur_target="$v" ;;
          versions:command)     cur_target="$v" ;;
          versions:pattern)     cur_pattern="$v" ;;
          services:name)        cur_name="$v" ;;
          services:expected_state) cur_state="$v" ;;
        esac
      fi
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]+([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v; v="$(_unquote "$(_trim "${BASH_REMATCH[2]}")")"
      case "$section:$k" in
        disk_space:path)     cur_path="$v" ;;
        disk_space:min_free_mb) cur_min="$v" ;;
        backups:path)         cur_path="$v" ;;
        backups:max_age_hours) cur_max_age="$v" ;;
        versions:source)      cur_source="$v" ;;
        versions:path)        cur_target="$v" ;;
        versions:command)     cur_target="$v" ;;
        versions:pattern)     cur_pattern="$v" ;;
        services:name)        cur_name="$v" ;;
        services:expected_state) cur_state="$v" ;;
      esac
      continue
    fi
  done < "$file"

  flush_current_section
}

load_manifest() {
  local file="$1"
  [[ -f "$file" ]] || die "manifest not found: $file"

  case "$file" in
    *.json)       load_manifest_json "$file" ;;
    *.yml|*.yaml) load_manifest_yaml "$file" ;;
    *)
      if [[ "$(head -c1 <(_trim "$(cat "$file")"))" == "{" ]]; then
        load_manifest_json "$file"
      else
        load_manifest_yaml "$file"
      fi
      ;;
  esac

  local total=$(( ${#PREFLIGHT_DISK_SPACE[@]} + ${#PREFLIGHT_BACKUPS[@]} + ${#PREFLIGHT_VERSIONS[@]} + ${#PREFLIGHT_SERVICES[@]} + ${#PREFLIGHT_ZOMBIE_PATTERNS[@]} ))
  (( total > 0 )) || die "manifest has no checkable items (disk_space/backups/versions/services/zombie_patterns all empty): $file"
}
