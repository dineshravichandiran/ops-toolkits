# Apache.ps1 - a constrained Apache httpd.conf reader.
#
# Not a general Apache config parser, same scope as the Bash version's
# lib/apache.sh: top-level directives and single-level <Location>/
# <Directory> blocks. One real difference from the Bash version: .NET
# regex (which PowerShell's -match uses) is case-insensitive by default,
# so directive matching here doesn't need the "canonical case only"
# limitation the Bash version has -- that limitation exists specifically
# because macOS's /usr/bin/awk has no IGNORECASE (a gawk-only
# extension), which doesn't apply here at all.

# $Lines is deliberately NOT [Parameter(Mandatory)] -- see the comment
# above Get-PolicyScalar in lib/Policy.ps1 for why (a real, reproduced
# `pwsh -File`-specific parameter-binding bug, not a style choice).
function Get-ApacheDirective {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Directive)

    $pattern = "^\s*${Directive}\s+(.+)$"
    $match = $Lines | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if (-not $match) { return "" }
    $null = $match -match $pattern
    return $Matches[1].Trim().Trim('"')
}

function Get-ApacheBlock {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Needle)

    $body = @()
    $inBlock = $false
    foreach ($line in $Lines) {
        if (-not $inBlock -and $line -match "<${Tag}\b" -and $line -match [regex]::Escape($Needle)) {
            $inBlock = $true
            continue
        }
        if ($inBlock -and $line -match "</${Tag}>") {
            $inBlock = $false
            continue
        }
        if ($inBlock) { $body += $line }
    }
    return $body
}

function Test-ServerTokens {
    param([string[]]$Lines, [string]$Expected)
    $actual = Get-ApacheDirective $Lines 'ServerTokens'
    if (-not $actual) { $actual = 'Full' }   # Apache's documented default when unset

    if ($actual -ieq $Expected) {
        Write-Finding -Status PASS -Name 'apache:ServerTokens' -Message "set to '$actual' as expected"
    } else {
        Write-Finding -Status FAIL -Name 'apache:ServerTokens' -Message "set to '$actual', policy expects '$Expected'"
    }
}

function Test-ServerSignature {
    param([string[]]$Lines, [string]$Expected)
    $actual = Get-ApacheDirective $Lines 'ServerSignature'
    if (-not $actual) { $actual = 'Off' }    # Apache's documented default when unset

    if ($actual -ieq $Expected) {
        Write-Finding -Status PASS -Name 'apache:ServerSignature' -Message "set to '$actual' as expected"
    } else {
        Write-Finding -Status FAIL -Name 'apache:ServerSignature' -Message "set to '$actual', policy expects '$Expected'"
    }
}

function Test-ApacheTimeout {
    param([string[]]$Lines, [int]$MaxSeconds)
    $actualStr = Get-ApacheDirective $Lines 'Timeout'
    if (-not $actualStr) { $actualStr = '60' }  # Apache 2.4's documented default when unset
    $actual = [int]$actualStr

    if ($actual -le $MaxSeconds) {
        Write-Finding -Status PASS -Name 'apache:Timeout' -Message "${actual}s (policy max ${MaxSeconds}s)"
    } else {
        Write-Finding -Status FAIL -Name 'apache:Timeout' -Message "${actual}s exceeds policy max of ${MaxSeconds}s"
    }
}

function Test-HandlerRestricted {
    param([string[]]$Lines, [string]$Path, [string]$Label)

    $block = Get-ApacheBlock $Lines 'Location' $Path
    if ($block.Count -eq 0) {
        Write-Finding -Status PASS -Name "apache:${Label}" -Message "no <Location `"$Path`"> block configured, handler not enabled"
        return
    }

    $requireLine = $block | Where-Object { $_ -match '^\s*Require\s+' } | Select-Object -Last 1
    if ($requireLine) {
        Write-Finding -Status PASS -Name "apache:${Label}" -Message "restricted ($($requireLine.Trim()))"
        return
    }

    $oldStyle = $block | Where-Object { $_ -match '^\s*(Order|Allow|Deny)\s+' }
    if ($oldStyle) {
        Write-Finding -Status WARN -Name "apache:${Label}" -Message "uses old-style Order/Allow/Deny -- verify manually, not evaluated by this tool"
        return
    }

    Write-Finding -Status FAIL -Name "apache:${Label}" -Message "<Location `"$Path`"> has no Require directive -- exposed with no access restriction"
}

function Test-ServerStatus { param([string[]]$Lines) Test-HandlerRestricted $Lines '/server-status' 'server-status' }
function Test-ServerInfo   { param([string[]]$Lines) Test-HandlerRestricted $Lines '/server-info' 'server-info' }

function Test-DirectoryListing {
    param([string[]]$Lines, [string]$Path)

    $block = Get-ApacheBlock $Lines 'Directory' $Path
    if ($block.Count -eq 0) {
        Write-Finding -Status WARN -Name "apache:directory_listing:${Path}" -Message "no <Directory `"$Path`"> block found -- cannot confirm indexing is disabled, verify manually"
        return
    }

    $optionsLine = $block | Where-Object { $_ -match '^\s*Options\s+' } | Select-Object -Last 1
    if (-not $optionsLine) {
        Write-Finding -Status WARN -Name "apache:directory_listing:${Path}" -Message "no Options directive in <Directory `"$Path`"> -- cannot confirm indexing is disabled, verify manually"
    } elseif ($optionsLine -match '(^|\s)\+?Indexes(\s|$)') {
        Write-Finding -Status FAIL -Name "apache:directory_listing:${Path}" -Message "Options includes Indexes -- directory listing is enabled"
    } else {
        Write-Finding -Status PASS -Name "apache:directory_listing:${Path}" -Message "directory listing disabled"
    }
}
