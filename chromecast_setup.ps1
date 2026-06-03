#Requires -Version 5.1
<#
.SYNOPSIS
    Automates WiFi configuration of a factory-reset Chromecast H2G2-42.
.DESCRIPTION
    Scans for a Chromecast hotspot, fetches the device RSA public key, encrypts
    home WiFi credentials, pushes config via the Chromecast setup API, then
    reconnects the controlling machine to the home network and verifies success.
.NOTES
    Authorship:
        Original research scripts (connect_wifi.sh, commit_wifi.sh,
        encrypt_password.sh, create_pem.sh, create_key_rsa.sh, get_info.sh,
        verify_wifi.sh) written by @rbrisita (https://github.com/rbrisita).
        This all-in-one script inlines and extends that original work.
        Developed with AI assistance (Claude, by Anthropic).

    Tested on:
        Windows 11 / PowerShell 5.1 and 7.4.13 / Chromecast H2G2-42

    Compatible    : Windows PowerShell 5.1 and PowerShell 7+
    Hard requires : netsh (built-in Windows)
    Crypto        : .NET System.Security.Cryptography (built-in, no OpenSSL needed)
    Admin         : required for netsh profile management; script re-launches
                    elevated automatically if needed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Chromecast API constants -------------------------------------------------
$CC_PORT       = '8008'
$CC_HOTSPOT_IP = '192.168.255.249'      # Static IP the Chromecast hotspot self-assigns
$CC_EUREKA     = '/setup/eureka_info'
$CC_CFG_NET    = '/setup/configured_networks'

# --- Globals set during execution --------------------------------------------
$script:Iface  = ''    # Wireless interface name  (e.g. "Wi-Fi")
$script:CcSsid = ''    # Chosen Chromecast hotspot SSID
$script:CcIp   = ''    # Chromecast IP or hostname on the active network

# --- Temp workspace - scrubbed in finally block -------------------------------
$WorkDir = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
$null    = New-Item -ItemType Directory -Path $WorkDir

# =============================================================================
# WlanScan P/Invoke
# netsh wlan show networks only reads the background scan cache; it cannot
# force a fresh scan. WlanScan() tells the driver to scan all bands immediately.
#
# WLAN_INTERFACE_INFO_LIST layout (wlanapi.h):
#   DWORD dwNumberOfItems  (+0, 4 bytes)
#   DWORD dwIndex          (+4, 4 bytes)
#   WLAN_INTERFACE_INFO[]  (+8, 532 bytes each):
#     GUID   InterfaceGuid               (16 bytes)
#     WCHAR  strInterfaceDescription[256] (512 bytes)
#     DWORD  isState                     (4 bytes)
# =============================================================================

$wlanCode = @'
using System;
using System.Runtime.InteropServices;

public static class WlanScanHelper {
    [DllImport("wlanapi.dll")]
    static extern uint WlanOpenHandle(uint ver, IntPtr res, out uint negVer, out IntPtr handle);

    [DllImport("wlanapi.dll")]
    static extern uint WlanCloseHandle(IntPtr handle, IntPtr res);

    [DllImport("wlanapi.dll")]
    static extern uint WlanScan(IntPtr handle, ref Guid ifGuid, IntPtr ssid, IntPtr ie, IntPtr res);

    [DllImport("wlanapi.dll")]
    static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr res, out IntPtr ifList);

    [DllImport("wlanapi.dll")]
    static extern void WlanFreeMemory(IntPtr mem);

    public static bool TriggerScan() {
        uint neg; IntPtr h;
        if (WlanOpenHandle(2, IntPtr.Zero, out neg, out h) != 0) return false;
        try {
            IntPtr list;
            if (WlanEnumInterfaces(h, IntPtr.Zero, out list) != 0) return false;
            try {
                int count = Marshal.ReadInt32(list);
                for (int i = 0; i < count; i++) {
                    IntPtr item = new IntPtr(list.ToInt64() + 8 + i * 532);
                    byte[] b = new byte[16];
                    Marshal.Copy(item, b, 0, 16);
                    Guid g = new Guid(b);
                    WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                }
                return true;
            } finally { WlanFreeMemory(list); }
        } finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
}
'@

Add-Type -TypeDefinition $wlanCode

# =============================================================================
# SECTION 1: Logging
# =============================================================================

function Write-Log  { param([string]$Msg) Write-Host "`n[*] $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "    + $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[!] $Msg"   -ForegroundColor Yellow }

# Writes a red error and throws so the finally block in Main still runs.
function Write-Fail {
    param([string]$Msg)
    Write-Host "[!] $Msg" -ForegroundColor Red
    throw $Msg
}

# =============================================================================
# SECTION 2: Admin Elevation
# Connecting to new SSIDs and managing WLAN profiles requires administrator
# rights on Windows. If not elevated, re-launch self with RunAs and exit.
# =============================================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-ElevatedIfNeeded {
    if (Test-IsAdmin) { return }

    Write-Warn 'Administrator privileges required. Re-launching elevated...'
    # Use pwsh.exe for PowerShell 7+, powershell.exe for 5.1
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process -FilePath $exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

# =============================================================================
# SECTION 3: Wireless Interface Detection
# Reads the first interface name reported by netsh wlan show interfaces.
# =============================================================================

function Get-WifiInterface {
    Write-Log 'Detecting wireless interface...'

    $output = netsh wlan show interfaces 2>&1
    $match  = $output | Select-String '^\s+Name\s+:\s+(.+)$'

    if (-not $match) {
        Write-Fail 'No wireless interface found. Ensure a WiFi adapter is installed and enabled.'
    }

    $script:Iface = $match[0].Matches[0].Groups[1].Value.Trim()
    Write-Ok "Interface: $($script:Iface)"
}

# =============================================================================
# SECTION 4: Scan for Chromecast SSIDs
# Triggers a fresh scan via netsh, then filters results for SSID names
# starting with "Chromecast". Presents a numbered menu if multiple are found.
# =============================================================================

function Select-ChromecastSsid {
    Write-Log 'Scanning for Chromecast hotspots (this may take a few seconds)...'

    # Trigger an immediate driver-level scan then allow results to populate.
    # netsh alone only reads the background cache; WlanScan() forces all bands now.
    $null = [WlanScanHelper]::TriggerScan()
    Start-Sleep -Seconds 5

    $output = netsh wlan show networks mode=bssid
    $ssids  = @(
        $output |
        Select-String '^\s*SSID \d+\s+:\s+(Chromecast.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
        Sort-Object -Unique
    )

    if ($ssids.Count -eq 0) {
        Write-Fail 'No Chromecast SSIDs found. Ensure the device is factory-reset and broadcasting.'
    }

    if ($ssids.Count -eq 1) {
        $script:CcSsid = $ssids[0]
        Write-Ok "Found: $($script:CcSsid)"
        return
    }

    Write-Host "`n    Multiple Chromecasts found:"
    for ($i = 0; $i -lt $ssids.Count; $i++) {
        Write-Host "      [$($i + 1)] $($ssids[$i])"
    }

    $sel = Read-Host "    Select [1-$($ssids.Count)]"
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $ssids.Count) {
        Write-Fail "Invalid selection: $sel"
    }

    $script:CcSsid = $ssids[[int]$sel - 1]
    Write-Ok "Selected: $($script:CcSsid)"
}

# =============================================================================
# SECTION 5: WiFi Connect via netsh
# netsh requires a saved profile XML to connect to any network. We build a
# minimal profile on the fly, add it (removing any prior profile with the same
# name first), connect, then poll until State = connected or timeout.
# =============================================================================

function New-WifiProfileXml {
    param([string]$Ssid, [string]$Password)

    if ([string]::IsNullOrEmpty($Password)) {
        # Open network - used for Chromecast hotspot
        return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$Ssid</name>
  <SSIDConfig><SSID><name>$Ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security><authEncryption>
    <authentication>open</authentication>
    <encryption>none</encryption>
    <useOneX>false</useOneX>
  </authEncryption></security></MSM>
</WLANProfile>
"@
    }

    # WPA2-PSK - used for home network
    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$Ssid</name>
  <SSIDConfig><SSID><name>$Ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption>
      <authentication>WPA2PSK</authentication>
      <encryption>AES</encryption>
      <useOneX>false</useOneX>
    </authEncryption>
    <sharedKey>
      <keyType>passPhrase</keyType>
      <protected>false</protected>
      <keyMaterial>$Password</keyMaterial>
    </sharedKey>
  </security></MSM>
</WLANProfile>
"@
}

function Wait-WifiConnected {
    param([string]$Ssid, [int]$TimeoutSec = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $escaped  = [regex]::Escape($Ssid)

    while ((Get-Date) -lt $deadline) {
        $out = (netsh wlan show interfaces 2>&1) | Out-String
        if ($out -match "SSID\s+:\s+$escaped" -and $out -match 'State\s+:\s+connected') {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Connect-Wifi {
    param([string]$Ssid, [string]$Password = '')
    Write-Log "Connecting to '$Ssid'..."

    $profilePath = Join-Path $WorkDir 'profile.xml'
    New-WifiProfileXml -Ssid $Ssid -Password $Password |
        Out-File -FilePath $profilePath -Encoding utf8 -Force

    # Remove any pre-existing profile to avoid stale config conflicts
    $null = netsh wlan delete profile name="$Ssid" interface="$($script:Iface)" 2>&1

    $addOut = netsh wlan add profile filename="$profilePath" `
                    interface="$($script:Iface)" user=all 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to add WiFi profile for '$Ssid': $addOut"
    }

    $connOut = netsh wlan connect name="$Ssid" interface="$($script:Iface)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to initiate connection to '$Ssid': $connOut"
    }

    if (-not (Wait-WifiConnected -Ssid $Ssid -TimeoutSec 30)) {
        Write-Fail "Timed out waiting to connect to '$Ssid'."
    }

    Write-Ok "Connected to '$Ssid'."
}

# =============================================================================
# SECTION 6: HTTP helpers (TLS 1.2 + cert bypass + User-Agent suppression)
#
# PS 5.1 needs ServicePointManager for TLS and cert config; PS 7+ has the
# cleaner -SkipCertificateCheck flag.
#
# The Chromecast setup API returns 404 to any POST request carrying a
# browser-style User-Agent header, which Invoke-RestMethod adds automatically.
# Invoke-CcPost explicitly suppresses it via -Headers @{ 'User-Agent' = '' }.
# GET requests to eureka_info are unaffected and need no suppression.
# Confirmed by testing against a local HttpListener mirror and a live device.
# =============================================================================

function Set-TlsConfig {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

function Invoke-CcGet {
    param([string]$Uri)
    Set-TlsConfig
    $p = @{ Uri = $Uri; Method = 'GET'; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p['SkipCertificateCheck'] = $true }
    return Invoke-RestMethod @p
}

function Invoke-CcPost {
    param([string]$Uri, [string]$Body)

    # The Chromecast setup API returns 404 to any request carrying a browser-style
    # User-Agent header (which Invoke-RestMethod adds automatically). Passing an
    # empty string suppresses it, producing identical behaviour to HttpWebRequest.
    Set-TlsConfig
    $p = @{
        Uri         = $Uri
        Method      = 'POST'
        Body        = $Body
        ContentType = 'application/json'
        Headers     = @{ 'User-Agent' = '' }
        ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p['SkipCertificateCheck'] = $true }
    return Invoke-RestMethod @p
}

# =============================================================================
# SECTION 7: Fetch Chromecast Device Info
# Inlines get_info.sh -- fetches /setup/eureka_info from the device.
# Extends it with mDNS, static IP, and arp -a fallbacks.
# =============================================================================

function Get-EurekaInfo {
    Write-Log 'Fetching Chromecast device info...'

    foreach ($endpoint in @(
        @{ Url = "http://chromecast.local:${CC_PORT}${CC_EUREKA}"; Label = 'chromecast.local';  Ip = 'chromecast.local' },
        @{ Url = "http://${CC_HOTSPOT_IP}:${CC_PORT}${CC_EUREKA}"; Label = $CC_HOTSPOT_IP;      Ip = $CC_HOTSPOT_IP    }
    )) {
        try {
            $info          = Invoke-CcGet -Uri $endpoint.Url
            $script:CcIp   = $endpoint.Ip
            Write-Ok "Reached via $($endpoint.Label)"
            return $info
        } catch { <# try next endpoint #> }
    }

    # Fall back: parse arp -a for dynamic entries and probe each
    Write-Warn 'mDNS and static IP failed; scanning via arp -a...'

    $ips = @(
        arp -a 2>&1 |
        Select-String '(\d+\.\d+\.\d+\.\d+)\s+[\da-f-]+\s+dynamic' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    )

    foreach ($ip in $ips) {
        try {
            $url           = "http://${ip}:${CC_PORT}${CC_EUREKA}"
            $info          = Invoke-CcGet -Uri $url
            $script:CcIp   = $ip
            Write-Ok "Reached via arp fallback: $ip"
            return $info
        } catch { <# try next IP #> }
    }

    Write-Fail 'Could not reach Chromecast on hotspot network. Is the device broadcasting?'
}

# =============================================================================
# SECTION 8: RSA Encryption (.NET - no OpenSSL required)
#
# Inlines the logic of create_key_rsa.sh / create_pem.sh / encrypt_password.sh.
#
# The public_key field from eureka_info is a base64-encoded DER blob in PKCS#1
# RSAPublicKey format (a bare SEQUENCE of two INTEGERs: modulus and exponent).
# We parse the ASN.1 DER manually to extract those values, import them into
# RSACryptoServiceProvider, and encrypt with PKCS#1 v1.5 padding - which
# matches the default behaviour of `openssl pkeyutl -encrypt`.
#
# Read-DerLength handles both short-form (1 byte) and long-form (multi-byte)
# DER length encodings, covering any RSA key size.
# =============================================================================

function Read-DerLength {
    param([byte[]]$Data, [int]$Pos)
    $first = $Data[$Pos]
    if ($first -lt 0x80) { return @($first, 1) }
    $numBytes = $first -band 0x7F
    $len      = 0
    for ($i = 1; $i -le $numBytes; $i++) {
        $len = ($len -shl 8) -bor $Data[$Pos + $i]
    }
    return @($len, (1 + $numBytes))
}

function ConvertFrom-Pkcs1PublicKey {
    param([string]$Base64Key)

    $der = [Convert]::FromBase64String($Base64Key)
    $pos = 0

    # Outer SEQUENCE (tag 0x30)
    if ($der[$pos] -ne 0x30) { Write-Fail 'Invalid PKCS#1 key: expected SEQUENCE tag (0x30).' }
    $pos++
    $r    = Read-DerLength $der $pos
    $pos += $r[1]

    # Modulus INTEGER (tag 0x02)
    if ($der[$pos] -ne 0x02) { Write-Fail 'Invalid PKCS#1 key: expected INTEGER tag for modulus.' }
    $pos++
    $r      = Read-DerLength $der $pos
    $modLen = $r[0]
    $pos   += $r[1]
    # Strip leading 0x00 sign byte that DER uses to keep positive integers unambiguous
    if ($der[$pos] -eq 0x00) { $pos++; $modLen-- }
    $modulus = $der[$pos..($pos + $modLen - 1)]
    $pos    += $modLen

    # Exponent INTEGER (tag 0x02)
    if ($der[$pos] -ne 0x02) { Write-Fail 'Invalid PKCS#1 key: expected INTEGER tag for exponent.' }
    $pos++
    $r      = Read-DerLength $der $pos
    $expLen = $r[0]
    $pos   += $r[1]
    $exponent = $der[$pos..($pos + $expLen - 1)]

    $params          = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = $modulus
    $params.Exponent = $exponent
    return $params
}

function Protect-WifiPassword {
    param([string]$PublicKeyB64, [string]$Password)

    $rsaParams = ConvertFrom-Pkcs1PublicKey -Base64Key $PublicKeyB64

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.ImportParameters($rsaParams)

    $pwBytes   = [System.Text.Encoding]::UTF8.GetBytes($Password)
    # $false = PKCS#1 v1.5 padding, matching `openssl pkeyutl -encrypt` default
    $encrypted = $rsa.Encrypt($pwBytes, $false)
    $rsa.Dispose()

    return [Convert]::ToBase64String($encrypted)
}

# =============================================================================
# SECTION 9: Configure Chromecast Over Hotspot API
# Inlines connect_wifi.sh and commit_wifi.sh.
# keep_hotspot_until_connected gives the controlling device time to reconnect
# before the Chromecast drops its own hotspot.
# =============================================================================

function Set-ChromecastWifi {
    param([string]$Ssid, [string]$EncPasswd)

    $base = "http://$($script:CcIp):${CC_PORT}"

    Write-Log 'Sending WiFi credentials to Chromecast...'
    $body = "{`"ssid`":`"$Ssid`",`"wpa_auth`":7,`"wpa_cipher`":4,`"enc_passwd`":`"$EncPasswd`"}"
    $null = Invoke-CcPost -Uri "$base/setup/connect_wifi" -Body $body
    Write-Ok 'Credentials sent.'

    Write-Log 'Committing WiFi configuration...'
    $null = Invoke-CcPost -Uri "$base/setup/save_wifi" -Body '{"keep_hotspot_until_connected": true}'
    Write-Ok 'Configuration committed.'
}

# =============================================================================
# SECTION 10: Verify Chromecast on Home Network
# Inlines verify_wifi.sh -- probes /setup/configured_networks on the device.
# Extends it with mDNS and arp -a fallbacks for IP discovery.
# =============================================================================

function Confirm-ChromecastOnline {
    Write-Log 'Waiting 15s for Chromecast to join home network...'
    Start-Sleep -Seconds 15

    # 1. mDNS - cheapest, no extra tools; Resolve-DnsName is built-in on Windows
    try {
        $null = Resolve-DnsName 'chromecast.local' -ErrorAction Stop
        $null = Invoke-CcGet -Uri "http://chromecast.local:${CC_PORT}${CC_CFG_NET}"
        Write-Ok 'Chromecast is online at chromecast.local'
        return
    } catch { <# fall through #> }

    # 2. arp -a fallback
    Write-Warn 'mDNS lookup failed; scanning via arp -a...'

    $ips = @(
        arp -a 2>&1 |
        Select-String '(\d+\.\d+\.\d+\.\d+)\s+[\da-f-]+\s+dynamic' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    )

    foreach ($ip in $ips) {
        try {
            $null = Invoke-CcGet -Uri "http://${ip}:${CC_PORT}${CC_CFG_NET}"
            Write-Ok "Chromecast is online at $ip"
            return
        } catch { <# try next IP #> }
    }

    Write-Warn "Chromecast not found on home network. It may still be connecting - check again in 30s."
}

# =============================================================================
# MAIN
# =============================================================================

function Main {
    try {
        # -- 1. Elevate if needed -------------------------------------------
        Invoke-ElevatedIfNeeded

        # -- 2. Detect wireless interface ----------------------------------
        Get-WifiInterface

        # -- 3. Prompt for home WiFi credentials ---------------------------
        Write-Host ''
        $HomeSsid   = Read-Host '  Home WiFi SSID'
        $HomePwdSec = Read-Host '  Home WiFi Password' -AsSecureString
        # Unwrap SecureString for use with crypto and netsh profile XML
        $HomePwd    = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                          [Runtime.InteropServices.Marshal]::SecureStringToBSTR($HomePwdSec))
        if ([string]::IsNullOrEmpty($HomeSsid)) { Write-Fail 'SSID cannot be empty.' }

        # -- 4. Scan for and select Chromecast hotspot ---------------------
        Select-ChromecastSsid

        # -- 5. Connect to Chromecast hotspot (open network) ---------------
        Connect-Wifi -Ssid $script:CcSsid -Password ''
        Start-Sleep -Seconds 3

        # -- 6. Fetch eureka_info and extract RSA public key ---------------
        $eureka    = Get-EurekaInfo
        $publicKey = $eureka.public_key
        if ([string]::IsNullOrEmpty($publicKey)) {
            Write-Fail 'Could not extract public_key from eureka_info.'
        }
        Write-Ok 'RSA public key extracted.'

        # -- 7. Encrypt home WiFi password with device public key ----------
        Write-Log 'Encrypting WiFi password...'
        $encPasswd = Protect-WifiPassword -PublicKeyB64 $publicKey -Password $HomePwd
        if ([string]::IsNullOrEmpty($encPasswd)) { Write-Fail 'Encryption produced empty result.' }
        Write-Ok 'Password encrypted.'

        # -- 8. Push config to Chromecast and commit -----------------------
        Set-ChromecastWifi -Ssid $HomeSsid -EncPasswd $encPasswd

        # -- 9. Reconnect controlling device to home WiFi ------------------
        Connect-Wifi -Ssid $HomeSsid -Password $HomePwd
        Start-Sleep -Seconds 5

        # -- 10. Verify Chromecast joined home network ----------------------
        Confirm-ChromecastOnline

        Write-Log "Done. Chromecast '$($script:CcSsid)' has been configured for '$HomeSsid'."

    } finally {
        # Always scrub temp workspace, even on error
        if (Test-Path $WorkDir) {
            Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
        }
    }
}

Main
