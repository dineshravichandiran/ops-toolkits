#!/usr/bin/env bash
# tomcat.sh - Tomcat server.xml checks, via `xmllint --xpath`.
#
# Real XML parsing rather than a regex scraper, unlike apache.sh's
# constrained line reader -- server.xml is genuine XML with attributes
# that can wrap across lines, self-close, or reorder, none of which a
# line-oriented reader handles safely. `xmllint` (libxml2) ships with
# macOS and is standard on most Linux distros already, so this adds no
# new dependency beyond what a Tomcat host almost certainly already has.

# tomcat_xpath <file> <xpath>
# Returns the string result, or empty if the xpath matched nothing.
# xmllint exits non-zero and writes "XPath set is empty" to stderr on no
# match -- both are expected outcomes here, not errors, so stderr is
# discarded and a non-zero exit is not treated as failure.
tomcat_xpath() {
  local file="$1" xpath="$2"
  xmllint --xpath "$xpath" "$file" 2>/dev/null
}

# --- Connector settings -------------------------------------------------
check_tomcat_connector() {
  local file="$1" port="$2" expected_protocol="$3" min_max_threads="$4" max_conn_timeout_ms="$5"
  local base="//Connector[@port=\"${port}\"]"
  local actual_protocol max_threads conn_timeout

  actual_protocol="$(tomcat_xpath "$file" "string(${base}/@protocol)")"
  if [[ -z "$actual_protocol" ]]; then
    report "FAIL" "tomcat:connector:${port}" "no <Connector port=\"${port}\"> found in server.xml"
    return
  fi

  if [[ "$actual_protocol" == "$expected_protocol" ]]; then
    report "PASS" "tomcat:connector:${port}:protocol" "protocol is '${actual_protocol}' as expected"
  else
    report "FAIL" "tomcat:connector:${port}:protocol" "protocol is '${actual_protocol}', policy expects '${expected_protocol}'"
  fi

  max_threads="$(tomcat_xpath "$file" "string(${base}/@maxThreads)")"
  [[ -z "$max_threads" ]] && max_threads="200"   # Tomcat's documented default
  if [[ "$max_threads" =~ ^[0-9]+$ ]] && (( max_threads >= min_max_threads )); then
    report "PASS" "tomcat:connector:${port}:maxThreads" "${max_threads} (policy minimum ${min_max_threads})"
  else
    report "FAIL" "tomcat:connector:${port}:maxThreads" "${max_threads} is below policy minimum of ${min_max_threads}"
  fi

  conn_timeout="$(tomcat_xpath "$file" "string(${base}/@connectionTimeout)")"
  [[ -z "$conn_timeout" ]] && conn_timeout="60000"   # Tomcat's documented default
  if [[ "$conn_timeout" =~ ^[0-9]+$ ]] && (( conn_timeout <= max_conn_timeout_ms )); then
    report "PASS" "tomcat:connector:${port}:connectionTimeout" "${conn_timeout}ms (policy max ${max_conn_timeout_ms}ms)"
  else
    report "FAIL" "tomcat:connector:${port}:connectionTimeout" "${conn_timeout}ms exceeds policy max of ${max_conn_timeout_ms}ms"
  fi
}

# --- Default admin webapps ----------------------------------------------
# manager/host-manager are separate WAR deployments under $CATALINA_BASE/
# webapps/, not something server.xml itself declares -- this checks
# directory presence, not server.xml content, which is the operationally
# real question ("is the app actually deployed") rather than a proxy for
# it. If the webapps directory can't be found at all, this is reported
# as WARN, not a silent PASS or an unjustified FAIL.
check_tomcat_default_apps() {
  local webapps_dir="$1"; shift
  local apps=("$@")

  if [[ ! -d "$webapps_dir" ]]; then
    report "WARN" "tomcat:default_apps" "webapps directory not found (${webapps_dir}) -- cannot verify, specify --webapps-dir"
    return
  fi

  local app
  for app in "${apps[@]}"; do
    if [[ -d "${webapps_dir}/${app}" ]]; then
      report "FAIL" "tomcat:default_apps:${app}" "still deployed at ${webapps_dir}/${app} -- remove in production"
    else
      report "PASS" "tomcat:default_apps:${app}" "not present"
    fi
  done
}

# --- SSL/TLS, only if a connector actually has it configured ------------
check_tomcat_ssl() {
  local file="$1" min_protocol="$2"
  local ssl_port protocols

  ssl_port="$(tomcat_xpath "$file" 'string(//Connector[@SSLEnabled="true"]/@port)')"
  if [[ -z "$ssl_port" ]]; then
    printf '  (no SSL/TLS connector configured, skipped)\n'
    return
  fi

  protocols="$(tomcat_xpath "$file" 'string(//Connector[@SSLEnabled="true"]/SSLHostConfig/@protocols)')"
  if [[ -z "$protocols" ]]; then
    report "WARN" "tomcat:ssl:${ssl_port}" "SSLHostConfig has no explicit protocols attribute -- verify manually against policy minimum of ${min_protocol}"
    return
  fi

  if grep -qE '(^|,)[[:space:]]*(SSLv2|SSLv3|TLSv1|TLSv1\.1)[[:space:]]*(,|$)' <<< "$protocols"; then
    report "FAIL" "tomcat:ssl:${ssl_port}" "protocols '${protocols}' include a deprecated protocol below policy minimum of ${min_protocol}"
  else
    report "PASS" "tomcat:ssl:${ssl_port}" "protocols '${protocols}' meet policy minimum of ${min_protocol}"
  fi
}
