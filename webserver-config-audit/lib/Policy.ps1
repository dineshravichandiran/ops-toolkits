# Policy.ps1 - reads policy.yaml into a plain object.
#
# Fixed schema, not a general YAML parser -- same approach and same
# reasoning as the Bash version's lib/policy.sh: the policy has a known,
# small set of keys, so this reads exactly those rather than pulling in
# a YAML module dependency for a handful of fixed fields.

# $Lines is deliberately NOT [Parameter(Mandatory)]: marking a
# [string[]] parameter Mandatory breaks argument binding specifically
# when the array being passed came from Get-Content and the script is
# run via `pwsh -File` (works fine via `-Command`, and works fine with a
# literal array either way) -- PowerShell throws "Cannot bind argument
# to parameter 'Lines' because it is an empty string" even though the
# array is neither empty nor a string. Found by actually running this
# script with `pwsh -File`, not by reading the code -- every variation
# of it looks correct on inspection.
function Get-PolicyScalar {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Key)

    $pattern = "^\s*${Key}:\s*(.*)$"
    $match = $Lines | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if (-not $match) { return "" }
    $null = $match -match $pattern
    return $Matches[1].Trim().Trim('"')
}

function Get-PolicyList {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Header)

    $result = @()
    $inList = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "${Header}:") { $inList = $true; continue }
        if ($inList) {
            if ($trimmed -match '^-\s*(.*)$') {
                $result += $Matches[1].Trim().Trim('"')
            } else {
                $inList = $false
            }
        }
    }
    return $result
}

function Import-Policy {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { Write-Fatal "policy file not found: $Path" }
    $lines = Get-Content -Path $Path

    [pscustomobject]@{
        ApacheServerTokens         = Get-PolicyScalar $lines 'server_tokens'
        ApacheServerSignature      = Get-PolicyScalar $lines 'server_signature'
        ApacheTimeoutMaxSeconds    = [int](Get-PolicyScalar $lines 'timeout_max_seconds')
        ApacheRestrictServerStatus = (Get-PolicyScalar $lines 'restrict_server_status') -eq 'true'
        ApacheRestrictServerInfo   = (Get-PolicyScalar $lines 'restrict_server_info') -eq 'true'
        DirectoryListingDisabled   = Get-PolicyList $lines 'directory_listing_disabled'

        TomcatPort               = Get-PolicyScalar $lines 'port'
        TomcatProtocol            = Get-PolicyScalar $lines 'protocol'
        TomcatMinMaxThreads       = [int](Get-PolicyScalar $lines 'min_max_threads')
        TomcatMaxConnTimeoutMs    = [int](Get-PolicyScalar $lines 'max_connection_timeout_ms')
        TomcatSslMinProtocol      = Get-PolicyScalar $lines 'min_protocol'
        DefaultAppsMustBeAbsent   = Get-PolicyList $lines 'default_apps_must_be_absent'
    }
}
