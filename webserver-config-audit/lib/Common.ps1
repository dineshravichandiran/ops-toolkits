# Common.ps1 - shared helpers for the PowerShell counterpart.
#
# Same three-state PASS/WARN/FAIL model and exit-code convention as
# bin/webserver-config-audit (the Bash version): 0 PASS, 1 WARN present,
# 2 FAIL present, 3 usage/internal error. Dot-sourced into the main
# script, so functions here read/write $script:-scoped state that lives
# in the caller (the entry point script), not in this file.

$script:ItemsTotal = 0
$script:ItemsPass = 0
$script:ItemsWarn = 0
$script:ItemsFail = 0
$script:Findings = @()
# Set by the entry point before running any checks when -Json is given.
# Write-Host writes straight to the host UI stream, not the normal
# success-output stream -- unlike Bash's stdout, it cannot be silenced
# by redirecting output (`> $null` does nothing to it), so the only way
# to keep JSON mode's output pure JSON is for these functions to simply
# not call Write-Host at all while it's set. Found by actually running
# `-Json` and piping the result through a JSON parser, not by reading
# the code: it looks like ordinary redirect-and-discard would work.
$script:JsonMode = $false

function Write-Finding {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )

    $script:ItemsTotal++
    switch ($Status) {
        'PASS' { $script:ItemsPass++; $color = 'Green' }
        'WARN' { $script:ItemsWarn++; $color = 'Yellow'; $script:Findings += [pscustomobject]@{ Status = $Status; Name = $Name; Message = $Message } }
        'FAIL' { $script:ItemsFail++; $color = 'Red';    $script:Findings += [pscustomobject]@{ Status = $Status; Name = $Name; Message = $Message } }
    }

    if ($script:JsonMode) { return }
    $line = "[{0,-4}] {1,-32} {2}" -f $Status, $Name, $Message
    Write-Host $line -ForegroundColor $color
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    if ($script:JsonMode) { return }
    Write-Host ""
    Write-Host $Title -ForegroundColor White
}

function Write-Summary {
    Write-Host ""
    Write-Host "Summary" -ForegroundColor White
    Write-Host ("  items checked : {0}" -f $script:ItemsTotal)
    Write-Host ("  pass          : {0}" -f $script:ItemsPass)
    Write-Host ("  warn          : {0}" -f $script:ItemsWarn)
    Write-Host ("  fail          : {0}" -f $script:ItemsFail)

    if ($script:ItemsFail -gt 0 -or $script:ItemsWarn -gt 0) {
        Write-Host ""
        Write-Host "Findings" -ForegroundColor White
        foreach ($f in $script:Findings) {
            Write-Host ("  [{0}] {1}: {2}" -f $f.Status, $f.Name, $f.Message)
        }
    }

    Write-Host ""
    if ($script:ItemsFail -gt 0) {
        Write-Host "OVERALL: FAIL" -ForegroundColor Red
    } elseif ($script:ItemsWarn -gt 0) {
        Write-Host "OVERALL: WARN" -ForegroundColor Yellow
    } else {
        Write-Host "OVERALL: PASS" -ForegroundColor Green
    }
}

function Get-ExitCode {
    if ($script:ItemsFail -gt 0) { return 2 }
    if ($script:ItemsWarn -gt 0) { return 1 }
    return 0
}

function Write-Fatal {
    param([Parameter(Mandatory)][string]$Message)
    Write-Error "ERROR: $Message"
    exit 3
}
