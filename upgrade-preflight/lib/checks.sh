#!/usr/bin/env bash
# checks.sh - runs the checks described by a loaded manifest.
# Each function reports through report() from common.sh. Checks and
# reports only: nothing here ever writes, deletes, starts, or stops
# anything on the host it's checking.

# ---------------------------------------------------------------------------
# Disk space. Uses `df -kP` (1024-byte blocks), not `-h`: BSD/macOS df's
# `-P` silently forces raw 512-byte blocks and ignores `-h` entirely (a
# real bug caught the hard way building windchill-ops-toolkit's disk
# check), so `-k` is the one block size that means the same thing on both
# GNU and BSD df.
# ---------------------------------------------------------------------------
check_disk_space() {
  local entry path min_mb avail_kb avail_mb
  for entry in "${PREFLIGHT_DISK_SPACE[@]}"; do
    path="${entry%%|*}"
    min_mb="${entry#*|}"

    if [[ ! -d "$path" ]]; then
      report "FAIL" "disk:${path}" "path does not exist"
      continue
    fi

    avail_kb="$(df -kP "$path" 2>/dev/null | tail -1 | awk '{print $4}')"
    if [[ ! "$avail_kb" =~ ^[0-9]+$ ]]; then
      report "FAIL" "disk:${path}" "could not determine available space (df failed)"
      continue
    fi

    avail_mb=$(( avail_kb / 1024 ))
    if (( avail_mb >= min_mb )); then
      report "PASS" "disk:${path}" "${avail_mb}MB free (need >=${min_mb}MB)"
    else
      report "FAIL" "disk:${path}" "only ${avail_mb}MB free, need >=${min_mb}MB"
    fi
  done
}

# ---------------------------------------------------------------------------
# Backup freshness. `find -mmin` (minutes), not `-mtime` (whole days
# only, per windchill-ops-toolkit's log-retention check): an upgrade
# window is measured in hours, and day-granularity would accept a backup
# up to 47 hours old under a "24 hour" policy.
# ---------------------------------------------------------------------------
check_backups() {
  local entry path max_age_hours max_age_min
  for entry in "${PREFLIGHT_BACKUPS[@]}"; do
    path="${entry%%|*}"
    max_age_hours="${entry#*|}"
    max_age_min=$(( max_age_hours * 60 ))

    if [[ ! -e "$path" ]]; then
      report "FAIL" "backup:${path}" "backup file not found"
      continue
    fi

    if find "$path" -mmin "+${max_age_min}" 2>/dev/null | grep -q .; then
      report "FAIL" "backup:${path}" "older than ${max_age_hours}h"
    else
      report "PASS" "backup:${path}" "present and within ${max_age_hours}h"
    fi
  done
}

# ---------------------------------------------------------------------------
# Current installed version. Source is either a file (read verbatim) or
# a shell command (run and its stdout read) -- pluggable because "how do
# you find out what version is currently installed" varies by
# application (a VERSION file, an rpm/dpkg query, a `--version` flag...).
# With no `pattern`, this is purely a "can we even detect it" check;
# with one, the detected output must contain it.
# ---------------------------------------------------------------------------
check_versions() {
  local entry source target pattern content
  for entry in "${PREFLIGHT_VERSIONS[@]}"; do
    IFS='|' read -r source target pattern <<< "$entry"

    case "$source" in
      file)
        if [[ ! -r "$target" ]]; then
          report "FAIL" "version:${target}" "cannot read version file"
          continue
        fi
        content="$(cat "$target" 2>/dev/null)"
        ;;
      command)
        if ! content="$(bash -c "$target" 2>&1)"; then
          report "FAIL" "version:${target}" "version command failed: ${content}"
          continue
        fi
        ;;
      *)
        report "FAIL" "version:${target}" "unknown version source: ${source} (expected file or command)"
        continue
        ;;
    esac

    if [[ -z "$pattern" ]]; then
      report "PASS" "version:${target}" "detected: $(printf '%s' "$content" | head -1)"
    elif grep -q -- "$pattern" <<< "$content"; then
      report "PASS" "version:${target}" "found expected current version '${pattern}'"
    else
      report "FAIL" "version:${target}" "expected current version '${pattern}' not found (detected: $(printf '%s' "$content" | head -1))"
    fi
  done
}

# ---------------------------------------------------------------------------
# Service state. Same systemd-first, process-table-fallback approach as
# deploy-validator, including excluding this process's own pid/ppid from
# the pgrep match for the same reason documented in deploy-validator's
# README: without it, a service name that appears in this script's own
# invocation can match itself.
# ---------------------------------------------------------------------------
check_services() {
  local entry name expected_state is_running hits
  for entry in "${PREFLIGHT_SERVICES[@]}"; do
    name="${entry%%|*}"
    expected_state="${entry#*|}"
    is_running=0

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${name}"; then
      systemctl is-active --quiet "$name" && is_running=1
    else
      hits=$(pgrep -f "$name" 2>/dev/null | grep -v -x -e "$$" -e "$PPID" || true)
      [[ -n "$hits" ]] && is_running=1
    fi

    case "$expected_state" in
      running)
        if (( is_running )); then
          report "PASS" "service:${name}" "running, as expected"
        else
          report "FAIL" "service:${name}" "expected running, but not running"
        fi
        ;;
      stopped)
        if (( is_running )); then
          report "FAIL" "service:${name}" "expected stopped, but still running"
        else
          report "PASS" "service:${name}" "stopped, as expected"
        fi
        ;;
      *)
        report "FAIL" "service:${name}" "unknown expected_state: ${expected_state} (expected running or stopped)"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Zombie / defunct processes. Scoped to a configurable pattern rather
# than "any zombie anywhere" so this doesn't false-positive on an
# unrelated zombie elsewhere on a busy shared host that has nothing to do
# with the application being upgraded.
#
# Matched against the zombie's PARENT process's name, not the zombie's
# own -- a zombie has already exited, and once it has, its own command
# name is gone. Linux's ps keeps a trace of it ("app-worker <defunct>"),
# but macOS's ps reports every zombie's command as a bare "<defunct>"
# with no name at all, so pattern-matching the zombie itself is not
# portable. The parent is still a live process with a real, matchable
# name, and "zombies piling up under this specific parent" is the
# actually useful operational signal anyway -- it's what would show a
# worker pool that isn't reaping its children.
# ---------------------------------------------------------------------------
check_no_zombies() {
  local pattern
  for pattern in "${PREFLIGHT_ZOMBIE_PATTERNS[@]}"; do
    local stat pid ppid parent_comm count=0
    while read -r stat pid ppid; do
      [[ -z "$pid" ]] && continue
      parent_comm="$(ps -o comm= -p "$ppid" 2>/dev/null)"
      printf '%s' "$parent_comm" | grep -qi -- "$pattern" && ((count++))
    done < <(ps -eo stat,pid,ppid 2>/dev/null | awk '$1 ~ /Z/ {print $1, $2, $3}')

    if (( count > 0 )); then
      report "FAIL" "zombies:${pattern}" "${count} zombie process(es) under a parent matching '${pattern}'"
    else
      report "PASS" "zombies:${pattern}" "no zombie processes under a parent matching '${pattern}'"
    fi
  done
}

run_all_checks() {
  section "Disk space"
  if (( ${#PREFLIGHT_DISK_SPACE[@]} > 0 )); then
    check_disk_space
  else
    printf '  (none in manifest)\n'
  fi

  section "Backup freshness"
  if (( ${#PREFLIGHT_BACKUPS[@]} > 0 )); then
    check_backups
  else
    printf '  (none in manifest)\n'
  fi

  section "Current version"
  if (( ${#PREFLIGHT_VERSIONS[@]} > 0 )); then
    check_versions
  else
    printf '  (none in manifest)\n'
  fi

  section "Service state"
  if (( ${#PREFLIGHT_SERVICES[@]} > 0 )); then
    check_services
  else
    printf '  (none in manifest)\n'
  fi

  section "Zombie processes"
  if (( ${#PREFLIGHT_ZOMBIE_PATTERNS[@]} > 0 )); then
    check_no_zombies
  else
    printf '  (none in manifest)\n'
  fi
}
