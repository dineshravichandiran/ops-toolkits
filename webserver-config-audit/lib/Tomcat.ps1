# Tomcat.ps1 - Tomcat server.xml checks, using PowerShell's native [xml]
# type and Select-Xml -- no external dependency needed (the Bash version
# uses `xmllint`, since Bash has no built-in XML support at all; that
# whole dependency simply doesn't exist here).

function Test-TomcatConnector {
    param([xml]$Xml, [string]$Port, [string]$ExpectedProtocol, [int]$MinMaxThreads, [int]$MaxConnTimeoutMs)

    $connector = $Xml.SelectSingleNode("//Connector[@port='$Port']")
    if (-not $connector) {
        Write-Finding -Status FAIL -Name "tomcat:connector:${Port}" -Message "no <Connector port=`"$Port`"> found in server.xml"
        return
    }

    $actualProtocol = $connector.protocol
    if ($actualProtocol -eq $ExpectedProtocol) {
        Write-Finding -Status PASS -Name "tomcat:connector:${Port}:protocol" -Message "protocol is '$actualProtocol' as expected"
    } else {
        Write-Finding -Status FAIL -Name "tomcat:connector:${Port}:protocol" -Message "protocol is '$actualProtocol', policy expects '$ExpectedProtocol'"
    }

    $maxThreads = $connector.maxThreads
    if (-not $maxThreads) { $maxThreads = 200 }   # Tomcat's documented default
    $maxThreads = [int]$maxThreads
    if ($maxThreads -ge $MinMaxThreads) {
        Write-Finding -Status PASS -Name "tomcat:connector:${Port}:maxThreads" -Message "$maxThreads (policy minimum $MinMaxThreads)"
    } else {
        Write-Finding -Status FAIL -Name "tomcat:connector:${Port}:maxThreads" -Message "$maxThreads is below policy minimum of $MinMaxThreads"
    }

    $connTimeout = $connector.connectionTimeout
    if (-not $connTimeout) { $connTimeout = 60000 }   # Tomcat's documented default
    $connTimeout = [int]$connTimeout
    if ($connTimeout -le $MaxConnTimeoutMs) {
        Write-Finding -Status PASS -Name "tomcat:connector:${Port}:connectionTimeout" -Message "${connTimeout}ms (policy max ${MaxConnTimeoutMs}ms)"
    } else {
        Write-Finding -Status FAIL -Name "tomcat:connector:${Port}:connectionTimeout" -Message "${connTimeout}ms exceeds policy max of ${MaxConnTimeoutMs}ms"
    }
}

function Test-TomcatDefaultApps {
    param([string]$WebappsDir, [string[]]$Apps)

    if (-not (Test-Path $WebappsDir -PathType Container)) {
        Write-Finding -Status WARN -Name 'tomcat:default_apps' -Message "webapps directory not found ($WebappsDir) -- cannot verify, specify -WebappsDir"
        return
    }

    foreach ($app in $Apps) {
        $appPath = Join-Path $WebappsDir $app
        if (Test-Path $appPath -PathType Container) {
            Write-Finding -Status FAIL -Name "tomcat:default_apps:${app}" -Message "still deployed at $appPath -- remove in production"
        } else {
            Write-Finding -Status PASS -Name "tomcat:default_apps:${app}" -Message "not present"
        }
    }
}

function Test-TomcatSsl {
    param([xml]$Xml, [string]$MinProtocol)

    $sslConnector = $Xml.SelectSingleNode("//Connector[@SSLEnabled='true']")
    if (-not $sslConnector) {
        if (-not $script:JsonMode) { Write-Host "  (no SSL/TLS connector configured, skipped)" }
        return
    }
    $sslPort = $sslConnector.port

    $sslHostConfig = $sslConnector.SelectSingleNode('SSLHostConfig')
    $protocols = if ($sslHostConfig) { $sslHostConfig.protocols } else { $null }

    if (-not $protocols) {
        Write-Finding -Status WARN -Name "tomcat:ssl:${sslPort}" -Message "SSLHostConfig has no explicit protocols attribute -- verify manually against policy minimum of $MinProtocol"
        return
    }

    if ($protocols -match '(^|,)\s*(SSLv2|SSLv3|TLSv1|TLSv1\.1)\s*(,|$)') {
        Write-Finding -Status FAIL -Name "tomcat:ssl:${sslPort}" -Message "protocols '$protocols' include a deprecated protocol below policy minimum of $MinProtocol"
    } else {
        Write-Finding -Status PASS -Name "tomcat:ssl:${sslPort}" -Message "protocols '$protocols' meet policy minimum of $MinProtocol"
    }
}
