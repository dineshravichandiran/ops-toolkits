#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Checks an Apache httpd.conf and/or a Tomcat server.xml against a
  policy file, flagging configuration drift. Read-only.

.DESCRIPTION
  PowerShell counterpart to bin/webserver-config-audit (the Bash
  version). Same checks, same policy.yaml format, same PASS/WARN/FAIL
  model and 0/1/2/3 exit-code convention -- see README.md for what
  differs between the two and why.

.PARAMETER Policy
  Policy YAML to check against. Required.

.PARAMETER HttpdConf
  Apache httpd.conf-style config to audit.

.PARAMETER ServerXml
  Tomcat server.xml to audit.

.PARAMETER WebappsDir
  Where to look for default manager/host-manager webapps. Defaults to
  <ServerXml's directory>/../webapps.

.PARAMETER Json
  Emit a machine-readable JSON summary instead of text.

.EXAMPLE
  ./webserver-config-audit.ps1 -Policy policy.yaml -HttpdConf /etc/httpd/conf/httpd.conf

.EXAMPLE
  ./webserver-config-audit.ps1 -Policy policy.yaml -ServerXml /opt/tomcat/conf/server.xml -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Policy,
    [string]$HttpdConf,
    [string]$ServerXml,
    [string]$WebappsDir,
    [switch]$Json
)

$ScriptDir = Split-Path -Parent $PSCommandPath
$RootDir = Split-Path -Parent $ScriptDir

. (Join-Path $RootDir 'lib/Common.ps1')
. (Join-Path $RootDir 'lib/Policy.ps1')
. (Join-Path $RootDir 'lib/Apache.ps1')
. (Join-Path $RootDir 'lib/Tomcat.ps1')

$script:JsonMode = [bool]$Json

if (-not $HttpdConf -and -not $ServerXml) {
    Write-Error "at least one of -HttpdConf / -ServerXml is required"
    exit 3
}
if ($HttpdConf -and -not (Test-Path $HttpdConf -PathType Leaf)) {
    Write-Error "httpd.conf not found: $HttpdConf"
    exit 3
}
if ($ServerXml -and -not (Test-Path $ServerXml -PathType Leaf)) {
    Write-Error "server.xml not found: $ServerXml"
    exit 3
}

if ($ServerXml -and -not $WebappsDir) {
    # Resolve to an absolute path first: for a shallow relative path
    # like "conf/server.xml", Split-Path -Parent twice returns "" (a
    # relative path only has as many parent segments as it was given),
    # and Join-Path then fails on an empty Path. Resolve-Path always
    # returns an absolute path, so the two Split-Path calls always have
    # a real parent to find regardless of how the caller wrote -ServerXml.
    $resolvedServerXml = (Resolve-Path $ServerXml).Path
    $WebappsDir = Join-Path (Split-Path -Parent (Split-Path -Parent $resolvedServerXml)) 'webapps'
}

$policyData = Import-Policy -Path $Policy

if (-not $Json) {
    Write-Host "webserver-config-audit  |  policy: $Policy  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

if ($HttpdConf) {
    Write-Section "Apache ($HttpdConf)"
    $httpdLines = Get-Content -Path $HttpdConf

    Test-ServerTokens $httpdLines $policyData.ApacheServerTokens
    Test-ServerSignature $httpdLines $policyData.ApacheServerSignature
    Test-ApacheTimeout $httpdLines $policyData.ApacheTimeoutMaxSeconds
    if ($policyData.ApacheRestrictServerStatus) { Test-ServerStatus $httpdLines }
    if ($policyData.ApacheRestrictServerInfo) { Test-ServerInfo $httpdLines }
    foreach ($path in $policyData.DirectoryListingDisabled) {
        Test-DirectoryListing $httpdLines $path
    }
}

if ($ServerXml) {
    Write-Section "Tomcat ($ServerXml)"
    [xml]$xml = Get-Content -Path $ServerXml -Raw

    Test-TomcatConnector $xml $policyData.TomcatPort $policyData.TomcatProtocol `
        $policyData.TomcatMinMaxThreads $policyData.TomcatMaxConnTimeoutMs
    if ($policyData.DefaultAppsMustBeAbsent.Count -gt 0) {
        Test-TomcatDefaultApps $WebappsDir $policyData.DefaultAppsMustBeAbsent
    }
    Test-TomcatSsl $xml $policyData.TomcatSslMinProtocol
}

if ($Json) {
    $summary = [pscustomobject]@{
        policy      = $Policy
        timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        items_total = $script:ItemsTotal
        items_pass  = $script:ItemsPass
        items_warn  = $script:ItemsWarn
        items_fail  = $script:ItemsFail
        # @(...) wrapping matters: ConvertTo-Json unwraps a zero- or
        # one-element pipeline result to null/a bare object instead of
        # a JSON array, which would make a clean run's "findings" come
        # out as `null` rather than `[]`.
        findings    = @($script:Findings | ForEach-Object {
            [pscustomobject]@{ status = $_.Status; item = $_.Name; message = $_.Message }
        })
    }
    $summary | ConvertTo-Json -Depth 4
    exit (Get-ExitCode)
}

Write-Summary
exit (Get-ExitCode)
