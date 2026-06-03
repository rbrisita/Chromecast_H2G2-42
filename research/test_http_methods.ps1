#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses why Invoke-RestMethod and Invoke-WebRequest return 404 against
    the Chromecast setup API while HttpWebRequest succeeds.
.DESCRIPTION
    Runs a local HttpListener mirror on localhost:18008. Each method is fired
    from a [PowerShell]::Create() runspace (same process, separate thread) so
    the listener and the sender can handshake cleanly. Every header and body
    received is logged for side-by-side comparison.

    Part 1 - Local mirror: no Chromecast needed, shows exact request construction.
    Part 2 - Live Chromecast: optional, run while connected to Chromecast hotspot.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TEST_URI_PATH = '/setup/connect_wifi'
$TEST_BODY     = '{"ssid":"TestNetwork","wpa_auth":7,"wpa_cipher":4,"enc_passwd":"dGVzdEVuY3J5cHRlZFBhc3N3b3Jk"}'

# Ask the OS for a free port: bind TcpListener on port 0, read what was
# assigned, release it, then hand that port to HttpListener.
$tcpProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$tcpProbe.Start()
$MIRROR_PORT = $tcpProbe.LocalEndpoint.Port
$tcpProbe.Stop()

$MIRROR_BASE = "http://localhost:${MIRROR_PORT}"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# =============================================================================
# Runs a script block in a thread pool thread (same process as the listener).
# Returns a handle to wait on. Use Finish-Runspace to collect and clean up.
#
# Start-Job uses a separate process, which prevents the handshake between the
# sender and the HttpListener in the parent. PowerShell::Create() stays in-
# process so the TCP connection can complete and the listener can respond.
# =============================================================================

function Start-Runspace {
    param([ScriptBlock]$ScriptBlock, [object[]]$ArgumentList)
    $ps = [Management.Automation.PowerShell]::Create()
    $null = $ps.AddScript($ScriptBlock)
    foreach ($arg in $ArgumentList) { $null = $ps.AddArgument($arg) }
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Finish-Runspace {
    param([hashtable]$Runspace)
    $null = $Runspace.PS.EndInvoke($Runspace.Handle)
    $Runspace.PS.Dispose()
}

# =============================================================================
# Waits for one request on the listener, logs all headers and body, sends 200.
# Must be called after the runspace sender is already started (BeginInvoke).
# =============================================================================

function Receive-AndLogRequest {
    param([Net.HttpListener]$Listener, [string]$Label)

    Write-Host "`n  --- $Label ---" -ForegroundColor Cyan

    $task = $Listener.GetContextAsync()
    if (-not $task.Wait(10000)) {
        Write-Host "  [timeout] No request received within 10s." -ForegroundColor Yellow
        return
    }

    $req = $task.Result.Request

    Write-Host "  Method       : $($req.HttpMethod)"
    Write-Host "  URL          : $($req.Url)"
    Write-Host "  HTTP version : $($req.ProtocolVersion)"
    Write-Host "  ContentType  : $($req.ContentType)"
    Write-Host "  ContentLength: $($req.ContentLength64)"
    Write-Host "  Headers:"
    foreach ($key in $req.Headers.AllKeys) {
        Write-Host "    $($key.PadRight(20)): $($req.Headers[$key])"
    }
    if ($req.HasEntityBody) {
        $reader = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
        Write-Host "  Body         : $($reader.ReadToEnd())"
        $reader.Close()
    }

    # Send 200 to unblock the sender's request
    $task.Result.Response.StatusCode = 200
    $task.Result.Response.ContentLength64 = 0
    $task.Result.Response.Close()
}

# =============================================================================
# PART 1: Local mirror
# =============================================================================

Write-Host "`n============================================================="
Write-Host " PART 1: Local mirror (localhost:${MIRROR_PORT})"
Write-Host " Comparing raw request construction - no Chromecast needed."
Write-Host "=============================================================`n"

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("${MIRROR_BASE}/")
$listener.Start()
Write-Host "Mirror listening on ${MIRROR_BASE}..."

$mirrorUri = "${MIRROR_BASE}${TEST_URI_PATH}"

try {
    # -- Invoke-RestMethod --------------------------------------------------------
    $rs1 = Start-Runspace -ArgumentList $mirrorUri, $TEST_BODY -ScriptBlock {
        param($uri, $body)
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try { $null = Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType 'application/json' } catch {}
    }
    Receive-AndLogRequest -Listener $listener -Label 'Invoke-RestMethod'
    Finish-Runspace $rs1

    # -- Invoke-WebRequest --------------------------------------------------------
    $rs2 = Start-Runspace -ArgumentList $mirrorUri, $TEST_BODY -ScriptBlock {
        param($uri, $body)
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        try { $null = Invoke-WebRequest -Uri $uri -Method POST -Body $body -ContentType 'application/json' } catch {}
    }
    Receive-AndLogRequest -Listener $listener -Label 'Invoke-WebRequest'
    Finish-Runspace $rs2

    # -- HttpWebRequest -----------------------------------------------------------
    $rs3 = Start-Runspace -ArgumentList $mirrorUri, $TEST_BODY -ScriptBlock {
        param($uri, $body)
        $req               = [Net.HttpWebRequest]::Create($uri)
        $req.Method        = 'POST'
        $req.ContentType   = 'application/json'
        $req.AllowAutoRedirect = $false
        $bytes             = [Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $stream            = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        try { $resp = $req.GetResponse(); $resp.Close() } catch {}
    }
    Receive-AndLogRequest -Listener $listener -Label 'HttpWebRequest'
    Finish-Runspace $rs3

} finally {
    # Always release the port - prevents the "existing registration" error on re-runs
    $listener.Stop()
    $listener.Close()
}

# =============================================================================
# PART 2: Live Chromecast (optional)
# =============================================================================

Write-Host "`n============================================================="
Write-Host " PART 2: Live Chromecast (optional)"
Write-Host "=============================================================`n"

$runLive = Read-Host "Run live Chromecast test? Requires connection to Chromecast hotspot. (y/n)"

if ($runLive -ne 'y') {
    Write-Host "Skipped.`n"
    exit 0
}

$ccIp    = Read-Host "Chromecast IP or hostname (e.g. 192.168.255.249 or chromecast.local)"
$liveUri = "http://${ccIp}:8008${TEST_URI_PATH}"
Write-Host "`nSending to: $liveUri`n"

# -- Invoke-RestMethod --------------------------------------------------------
Write-Host "  --- Invoke-RestMethod ---" -ForegroundColor Cyan
try {
    $null = Invoke-RestMethod -Uri $liveUri -Method POST -Body $TEST_BODY -ContentType 'application/json' -ErrorAction Stop
    Write-Host "  Status: 200 OK"
} catch [Net.WebException] {
    Write-Host "  Status: $([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)"
} catch {
    Write-Host "  Error : $($_.Exception.Message)"
}

# -- Invoke-WebRequest --------------------------------------------------------
Write-Host "`n  --- Invoke-WebRequest ---" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -Uri $liveUri -Method POST -Body $TEST_BODY -ContentType 'application/json' -ErrorAction Stop
    Write-Host "  Status: $($r.StatusCode) $($r.StatusDescription)"
} catch [Net.WebException] {
    Write-Host "  Status: $([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)"
} catch {
    Write-Host "  Error : $($_.Exception.Message)"
}

# -- HttpWebRequest -----------------------------------------------------------
Write-Host "`n  --- HttpWebRequest ---" -ForegroundColor Cyan
try {
    $req               = [Net.HttpWebRequest]::Create($liveUri)
    $req.Method        = 'POST'
    $req.ContentType   = 'application/json'
    $req.AllowAutoRedirect = $false
    $bytes             = [Text.Encoding]::UTF8.GetBytes($TEST_BODY)
    $req.ContentLength = $bytes.Length
    $stream            = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $response = $req.GetResponse()
    Write-Host "  Status: $([int]$response.StatusCode) $($response.StatusDescription)"
    $response.Close()
} catch [Net.WebException] {
    Write-Host "  Status: $([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)"
} catch {
    Write-Host "  Error : $($_.Exception.Message)"
}

# -- Invoke-RestMethod (User-Agent suppressed) --------------------------------
# Theory: Chromecast returns 404 to any request carrying a browser-style
# User-Agent. Passing an empty string suppresses the header entirely.
# If this returns 500 instead of 404 the theory is confirmed -- the only
# remaining difference from HttpWebRequest is the fake encrypted payload.
Write-Host "`n  --- Invoke-RestMethod (User-Agent suppressed) ---" -ForegroundColor Cyan
try {
    $null = Invoke-RestMethod -Uri $liveUri -Method POST -Body $TEST_BODY `
        -ContentType 'application/json' `
        -Headers @{ 'User-Agent' = '' } `
        -ErrorAction Stop
    Write-Host "  Status: 200 OK"
} catch [Net.WebException] {
    Write-Host "  Status: $([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)"
} catch {
    Write-Host "  Error : $($_.Exception.Message)"
}

Write-Host ""
