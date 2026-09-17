#!/usr/bin/env bash
# checks.sh - individual health checks.
# Each check is independent and reports through report() from common.sh.

# ---------------------------------------------------------------------------
# Disk usage. Windchill vaults and log directories fill quietly; this is the
# single most common cause of avoidable application outages in PLM estates.
# ---------------------------------------------------------------------------
check_disk_usage() {
  local warn="${DISK_WARN_PCT:-80}" crit="${DISK_CRIT_PCT:-90}"
  local mount used avail pct

  while read -r _ _ used avail pct mount; do
    pct="${pct%\%}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue

    local msg="${pct}% used, ${avail} free on ${mount}"
    if   (( pct >= crit )); then report "$STATUS_CRIT" "disk:${mount}" "$msg"
    elif (( pct >= warn )); then report "$STATUS_WARN" "disk:${mount}" "$msg"
    else                        report "$STATUS_OK"   "disk:${mount}" "$msg"
    fi
  done < <(df -hP -x tmpfs -x devtmpfs -x overlay 2>/dev/null | tail -n +2)
}

# ---------------------------------------------------------------------------
# Service liveness. Checks systemd first, falls back to a process-table match
# so the script still works on hosts without systemd or inside containers.
# ---------------------------------------------------------------------------
check_service() {
  local svc="$1" pattern="${2:-$1}"

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
    if systemctl is-active --quiet "$svc"; then
      report "$STATUS_OK" "service:${svc}" "active (systemd)"
    else
      report "$STATUS_CRIT" "service:${svc}" "inactive (systemd)"
    fi
    return
  fi

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    local count; count=$(pgrep -f "$pattern" | wc -l | tr -d ' ')
    report "$STATUS_OK" "service:${svc}" "${count} process(es) matching '${pattern}'"
  else
    report "$STATUS_WARN" "service:${svc}" "not running or not installed on this host"
  fi
}

# ---------------------------------------------------------------------------
# TCP port reachability. Confirms the service is actually accepting
# connections rather than merely having a live process.
# ---------------------------------------------------------------------------
check_port() {
  local host="$1" port="$2" label="${3:-${host}:${port}}"

  if timeout 3 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
    report "$STATUS_OK" "port:${label}" "accepting connections"
  else
    report "$STATUS_CRIT" "port:${label}" "no response within 3s"
  fi
}

# ---------------------------------------------------------------------------
# JVM memory reporting. Surfaces resident set size against the configured
# -Xmx so heap pressure is visible before an OutOfMemoryError appears.
# ---------------------------------------------------------------------------
check_jvm_memory() {
  local pattern="${1:-java}" found=0

  while read -r pid rss cmd; do
    [[ -z "$pid" ]] && continue
    found=1

    local rss_mb=$(( rss / 1024 ))
    local xmx_mb=0
    if [[ "$cmd" =~ -Xmx([0-9]+)([gGmM]) ]]; then
      local val="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
      case "$unit" in
        g|G) xmx_mb=$(( val * 1024 )) ;;
        m|M) xmx_mb=$val ;;
      esac
    fi

    if (( xmx_mb > 0 )); then
      local pct=$(( rss_mb * 100 / xmx_mb ))
      local msg="pid ${pid}: RSS ${rss_mb}MB of Xmx ${xmx_mb}MB (${pct}%)"
      if   (( pct >= ${JVM_CRIT_PCT:-90} )); then report "$STATUS_CRIT" "jvm:heap" "$msg"
      elif (( pct >= ${JVM_WARN_PCT:-75} )); then report "$STATUS_WARN" "jvm:heap" "$msg"
      else                                        report "$STATUS_OK"   "jvm:heap" "$msg"
      fi
    else
      report "$STATUS_OK" "jvm:heap" "pid ${pid}: RSS ${rss_mb}MB (no -Xmx declared)"
    fi
  done < <(ps -eo pid=,rss=,args= 2>/dev/null | grep -- "$pattern" | grep -v grep | head -10)

  (( found == 0 )) && report "$STATUS_OK" "jvm:heap" "no JVM processes matching '${pattern}'"
}

# ---------------------------------------------------------------------------
# Ageing log files. Reports what would be reclaimed; deletion only happens
# when --apply is passed, so a routine run can never destroy evidence
# needed for an open investigation.
# ---------------------------------------------------------------------------
check_old_logs() {
  local dir="$1" days="${LOG_RETENTION_DAYS:-30}"

  [[ -d "$dir" ]] || { report "$STATUS_OK" "logs:${dir}" "directory not present, skipped"; return; }

  local count size
  count=$(find "$dir" -type f -name '*.log*' -mtime "+${days}" 2>/dev/null | wc -l | tr -d ' ')
  if (( count == 0 )); then
    report "$STATUS_OK" "logs:${dir}" "no files older than ${days} days"
    return
  fi

  size=$(find "$dir" -type f -name '*.log*' -mtime "+${days}" -printf '%s\n' 2>/dev/null \
         | awk '{t+=$1} END {printf "%.1f", t/1024/1024}')
  report "$STATUS_WARN" "logs:${dir}" "${count} file(s) older than ${days}d, ~${size}MB reclaimable"

  if confirm_or_skip "delete ${count} log file(s) in ${dir}"; then
    find "$dir" -type f -name '*.log*' -mtime "+${days}" -delete 2>/dev/null \
      && printf '  removed %s file(s) from %s\n' "$count" "$dir"
  fi
}

# ---------------------------------------------------------------------------
# Stale temp files, a recurring source of slow disk exhaustion.
# ---------------------------------------------------------------------------
check_temp_files() {
  local dir="$1" days="${TEMP_RETENTION_DAYS:-7}"

  [[ -d "$dir" ]] || { report "$STATUS_OK" "temp:${dir}" "directory not present, skipped"; return; }

  local count
  count=$(find "$dir" -type f -mtime "+${days}" 2>/dev/null | wc -l | tr -d ' ')
  if (( count > ${TEMP_WARN_COUNT:-500} )); then
    report "$STATUS_WARN" "temp:${dir}" "${count} file(s) older than ${days} days"
  else
    report "$STATUS_OK" "temp:${dir}" "${count} file(s) older than ${days} days"
  fi
}

# ---------------------------------------------------------------------------
# HTTP endpoint check, used for post-change validation after a restart.
# ---------------------------------------------------------------------------
check_http_endpoint() {
  local url="$1" expect="${2:-200}"

  command -v curl >/dev/null 2>&1 || {
    report "$STATUS_UNKNOWN" "http:${url}" "curl not available"; return; }

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")

  if [[ "$code" == "$expect" ]]; then
    report "$STATUS_OK" "http:${url}" "HTTP ${code} as expected"
  elif [[ "$code" == "000" ]]; then
    report "$STATUS_CRIT" "http:${url}" "no response or timeout"
  else
    report "$STATUS_CRIT" "http:${url}" "HTTP ${code}, expected ${expect}"
  fi
}
