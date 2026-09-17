#!/usr/bin/env pwsh
# run-tests.ps1 - runs the real bin/webserver-config-audit.ps1 against a
# fully compliant baseline and against copies each with exactly one
# deviation, asserting each is caught. Mirrors tests/run-tests.sh's
# scenarios so the two implementations are checked against the same
# cases.

$RootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Bin = Join-Path $RootDir 'bin/webserver-config-audit.ps1'
$PolicyFile = Join-Path $RootDir 'conf/policy.yaml'

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $WorkDir | Out-Null
try {
    $script:Pass = 0
    $script:Fail = 0

    function Assert-Exit {
        param([int]$Expected, [int]$Actual, [string]$Name)
        if ($Expected -eq $Actual) {
            Write-Host "  PASS  $Name"; $script:Pass++
        } else {
            Write-Host "  FAIL  $Name (expected exit $Expected, got $Actual)"; $script:Fail++
        }
    }

    function Assert-Contains {
        param([string]$Haystack, [string]$Needle, [string]$Name)
        if ($Haystack -like "*$Needle*") {
            Write-Host "  PASS  $Name"; $script:Pass++
        } else {
            Write-Host "  FAIL  $Name (output did not contain: $Needle)"; $script:Fail++
        }
    }

    function Invoke-Audit {
        # Named $AuditArgs, not $Args: PowerShell variable names are
        # case-insensitive, so a parameter called $Args silently shadows
        # the automatic $args variable. Splatting the shadowed copy with
        # @Args then passed nothing real through to `pwsh -File`, which
        # hit the child script's Mandatory -Policy parameter with no
        # value -- and since Mandatory-with-no-value makes PowerShell
        # interactively prompt for it, and this child's stdin was not an
        # interactive terminal, every single invocation hung waiting for
        # input that could never arrive, until something further up
        # timed it out.
        param([string[]]$AuditArgs)
        # $LASTEXITCODE must be read in the statement immediately after
        # the external call, not after piping through another cmdlet
        # (e.g. `... | Out-String`): the pipeline stage runs after
        # $LASTEXITCODE is set, and reading it afterward was silently
        # picking up a stale/reset value.
        $output = & pwsh -File $Bin @AuditArgs 2>&1
        $code = $LASTEXITCODE
        return @{ Output = ($output | Out-String); Code = $code }
    }

    Write-Host "Running tests"
    Write-Host ""

    Copy-Item (Join-Path $RootDir 'conf/example-httpd.conf') (Join-Path $WorkDir 'httpd.conf')
    Copy-Item (Join-Path $RootDir 'conf/example-server.xml') (Join-Path $WorkDir 'server.xml')

    $tomcatConf = Join-Path $WorkDir 'tomcat/conf'
    $tomcatWebapps = Join-Path $WorkDir 'tomcat/webapps/ROOT'
    New-Item -ItemType Directory -Path $tomcatConf -Force | Out-Null
    New-Item -ItemType Directory -Path $tomcatWebapps -Force | Out-Null
    Copy-Item (Join-Path $RootDir 'conf/example-server.xml') (Join-Path $tomcatConf 'server.xml')

    # =========================================================================
    # Scenario 1: fully-compliant configs
    # =========================================================================
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd.conf'),
                        '-ServerXml', (Join-Path $WorkDir 'server.xml'),
                        '-WebappsDir', (Join-Path $WorkDir 'tomcat/webapps'))
    Assert-Exit 0 $r.Code "fully-compliant configs: OVERALL PASS (exit 0)"
    Assert-Contains $r.Output "OVERALL: PASS" "fully-compliant configs report OVERALL: PASS"
    Assert-Contains $r.Output "fail          : 0" "fully-compliant configs have zero failures"
    Assert-Contains $r.Output "warn          : 0" "fully-compliant configs have zero warnings (real webapps dir given)"

    # =========================================================================
    # Scenario 2: Apache deviations, one at a time
    # =========================================================================
    $httpd = Get-Content (Join-Path $WorkDir 'httpd.conf')

    $httpd -replace 'ServerTokens Prod', 'ServerTokens Full' | Set-Content (Join-Path $WorkDir 'httpd-tokens.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-tokens.conf'))
    Assert-Exit 2 $r.Code "ServerTokens Full: OVERALL FAIL (exit 2)"
    Assert-Contains $r.Output "set to 'Full', policy expects 'Prod'" "ServerTokens deviation names actual vs expected"

    $httpd -replace 'ServerSignature Off', 'ServerSignature On' | Set-Content (Join-Path $WorkDir 'httpd-sig.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-sig.conf'))
    Assert-Exit 2 $r.Code "ServerSignature On: OVERALL FAIL"
    Assert-Contains $r.Output "set to 'On', policy expects 'Off'" "ServerSignature deviation names actual vs expected"

    $httpd -replace 'Timeout 60', 'Timeout 300' | Set-Content (Join-Path $WorkDir 'httpd-timeout.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-timeout.conf'))
    Assert-Exit 2 $r.Code "Timeout 300 exceeds policy max: OVERALL FAIL"
    Assert-Contains $r.Output "300s exceeds policy max of 60s" "Timeout deviation names actual vs expected"

    # Remove only the first "Require local" line (server-status's),
    # leaving server-info's intact.
    $removed = $false
    $lines = foreach ($line in $httpd) {
        if (-not $removed -and $line -match 'Require local') { $removed = $true; continue }
        $line
    }
    $lines | Set-Content (Join-Path $WorkDir 'httpd-status.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-status.conf'))
    Assert-Exit 2 $r.Code "server-status with no Require: OVERALL FAIL"
    Assert-Contains $r.Output "exposed with no access restriction" "unrestricted server-status is caught"

    $httpd -replace 'Options -Indexes -Includes', 'Options Indexes -Includes' | Set-Content (Join-Path $WorkDir 'httpd-indexes.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-indexes.conf'))
    Assert-Exit 2 $r.Code "Options Indexes enabled: OVERALL FAIL"
    Assert-Contains $r.Output "directory listing is enabled" "enabled directory listing is caught"

    $replaced = $false
    $oldStyleLines = foreach ($line in $httpd) {
        if (-not $replaced -and $line -match 'Require local') {
            $replaced = $true
            "    Order deny,allow"
            "    Allow from 127.0.0.1"
        } else {
            $line
        }
    }
    $oldStyleLines | Set-Content (Join-Path $WorkDir 'httpd-oldstyle.conf')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-oldstyle.conf'))
    Assert-Exit 1 $r.Code "old-style Order/Allow/Deny: OVERALL WARN (exit 1), not FAIL"
    Assert-Contains $r.Output "verify manually, not evaluated by this tool" "old-style access control is flagged for manual review"

    # =========================================================================
    # Scenario 3: Tomcat deviations, one at a time
    # =========================================================================
    $serverXml = Get-Content (Join-Path $WorkDir 'server.xml') -Raw

    # Replace only the first occurrence, same reasoning as the Bash
    # suite's first_match_only helper: several of these attributes
    # appear on more than one Connector.
    function Replace-First {
        param([string]$Text, [string]$Pattern, [string]$Replacement)
        $regex = [regex]::new([regex]::Escape($Pattern))
        return $regex.Replace($Text, $Replacement, 1)
    }

    Replace-First $serverXml 'maxThreads="200"' 'maxThreads="50"' | Set-Content (Join-Path $WorkDir 'server-threads.xml')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server-threads.xml'))
    Assert-Exit 2 $r.Code "maxThreads below policy minimum: OVERALL FAIL"
    Assert-Contains $r.Output "50 is below policy minimum of 150" "low maxThreads is caught"

    Replace-First $serverXml 'connectionTimeout="20000"' 'connectionTimeout="60000"' | Set-Content (Join-Path $WorkDir 'server-timeout.xml')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server-timeout.xml'))
    Assert-Exit 2 $r.Code "connectionTimeout above policy max: OVERALL FAIL"
    Assert-Contains $r.Output "60000ms exceeds policy max of 20000ms" "high connectionTimeout is caught"

    Replace-First $serverXml 'protocol="HTTP/1.1"' 'protocol="AJP/1.3"' | Set-Content (Join-Path $WorkDir 'server-protocol.xml')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server-protocol.xml'))
    Assert-Exit 2 $r.Code "wrong protocol on the policy port: OVERALL FAIL"
    Assert-Contains $r.Output "protocol is 'AJP/1.3', policy expects 'HTTP/1.1'" "wrong protocol names actual vs expected"

    Replace-First $serverXml 'protocols="TLSv1.2,TLSv1.3"' 'protocols="TLSv1.1,TLSv1.2"' | Set-Content (Join-Path $WorkDir 'server-ssl.xml')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server-ssl.xml'))
    Assert-Exit 2 $r.Code "SSL protocols include a deprecated one: OVERALL FAIL"
    Assert-Contains $r.Output "include a deprecated protocol" "deprecated SSL protocol is caught"

    Replace-First $serverXml 'port="8080"' 'port="9090"' | Set-Content (Join-Path $WorkDir 'server-noport.xml')
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server-noport.xml'))
    Assert-Exit 2 $r.Code "no connector on the policy port: OVERALL FAIL"
    Assert-Contains $r.Output "no <Connector port=`"8080`"> found" "missing connector on the policy port is caught"

    $managerDir = Join-Path $WorkDir 'tomcat/webapps/manager'
    New-Item -ItemType Directory -Path $managerDir -Force | Out-Null
    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server.xml'), '-WebappsDir', (Join-Path $WorkDir 'tomcat/webapps'))
    Assert-Exit 2 $r.Code "manager webapp still deployed: OVERALL FAIL"
    Assert-Contains $r.Output "still deployed at" "deployed manager app is caught"
    Remove-Item $managerDir -Recurse -Force

    $r = Invoke-Audit @('-Policy', $PolicyFile, '-ServerXml', (Join-Path $WorkDir 'server.xml'), '-WebappsDir', (Join-Path $WorkDir 'no-such-dir'))
    Assert-Exit 1 $r.Code "webapps dir cannot be found: OVERALL WARN (exit 1), not a silent PASS or FAIL"
    Assert-Contains $r.Output "cannot verify" "unverifiable default-apps check is flagged, not guessed"

    # =========================================================================
    # Scenario 4: usage and JSON
    # =========================================================================
    $r = Invoke-Audit @('-Policy', $PolicyFile)
    Assert-Exit 3 $r.Code "neither -HttpdConf nor -ServerXml given: usage error (exit 3)"

    $r = Invoke-Audit @('-Policy', (Join-Path $WorkDir 'no-such-policy.yaml'), '-HttpdConf', (Join-Path $WorkDir 'httpd.conf'))
    Assert-Exit 3 $r.Code "nonexistent policy file: usage error (exit 3)"

    $r = Invoke-Audit @('-Policy', $PolicyFile, '-HttpdConf', (Join-Path $WorkDir 'httpd-tokens.conf'), '-Json')
    Assert-Exit 2 $r.Code "-Json still exits 2 on a real FAIL"
    Assert-Contains $r.Output '"items_fail"' "-Json includes items_fail"
    Assert-Contains $r.Output '"status": "FAIL"' "-Json findings include the FAIL status"
    try {
        $null = $r.Output | ConvertFrom-Json
        Write-Host "  PASS  -Json output is valid JSON (parsed with ConvertFrom-Json)"; $script:Pass++
    } catch {
        Write-Host "  FAIL  -Json output is not valid JSON"; $script:Fail++
    }

    Write-Host ""
    Write-Host "passed: $($script:Pass)   failed: $($script:Fail)"
    if ($script:Fail -gt 0) { exit 1 }
    exit 0
} finally {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
