# Chromecast H2G2-42 WiFi Setup

Automates the WiFi configuration of a factory-reset Chromecast H2G2-42.
Scans for the device hotspot, fetches its RSA public key, encrypts your home
WiFi credentials, pushes the configuration via the Chromecast setup API, then
reconnects your machine to the home network and confirms the device is online.

Two versions are provided: a Bash script for Linux and a PowerShell script for
Windows.

## Authorship

The foundational shell scripts that reverse-engineered the Chromecast setup API
(`connect_wifi.sh`, `commit_wifi.sh`, `encrypt_password.sh`, `create_pem.sh`,
`create_key_rsa.sh`, `get_info.sh`, `verify_wifi.sh`) were written by
[@rbrisita](https://github.com/rbrisita).

`chromecast_setup.sh` and `chromecast_setup.ps1` are all-in-one scripts that
inline and extend that original work. They were developed with AI assistance
(Claude, by Anthropic).

---

## Tested On

| Platform | Version | Notes |
|---|---|---|
| Windows 11 | PowerShell 5.1 | Fully tested |
| Windows 11 | PowerShell 7.4.13 | Fully tested |
| Debian 11 | Bash | Fully tested |
| Chromecast | H2G2-42 | Only model tested |

---

## Requirements

### Bash (`chromecast_setup.sh`)
| Requirement | Notes |
|---|---|
| `openssl` | Required for RSA encryption |
| `curl` | Required for all Chromecast API calls |
| One of: `nmcli`, `iwctl`, `wpa_cli`, `wpa_supplicant` | WiFi management; detected automatically |
| `arp-scan` | Optional; used as IP discovery fallback |
| `iw` or `iwlist` | Required only if using `wpa_cli` / `wpa_supplicant` |

### PowerShell (`chromecast_setup.ps1`)
| Requirement | Notes |
|---|---|
| Windows PowerShell 5.1 or PowerShell 7+ | Both supported |
| `netsh wlan` | Built into Windows; handles all WiFi management |
| .NET `System.Security.Cryptography` | Built in; no OpenSSL needed |
| Administrator privileges | Script re-launches itself elevated automatically |

---

## Usage

### Linux -- Bash

```bash
chmod +x chromecast_setup.sh
./chromecast_setup.sh
```

The script will:

1. Auto-detect your wireless interface and WiFi manager
2. Prompt for your home WiFi SSID and password
3. Scan for `Chromecast*` hotspots and present a menu if more than one is found
4. Handle the rest automatically

> **Note:** `openssl rsa -RSAPublicKey_in` requires OpenSSL >= 1.0.2.
> Verify with `openssl version` before running.

---

### Windows -- PowerShell

Open PowerShell as Administrator (the script will prompt for elevation if
needed) and run:

```powershell
.\chromecast_setup.ps1
```

If Windows blocks the script with a "not digitally signed" error, unblock the
file first:

```powershell
Unblock-File -Path .\chromecast_setup.ps1
```

This removes the Mark of the Web tag that Windows attaches to downloaded files.
If your execution policy also needs updating:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Or bypass policy for a single run without changing any settings:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\chromecast_setup.ps1
```

The script will:

1. Auto-detect your wireless adapter
2. Prompt for your home WiFi SSID and password
3. Scan for `Chromecast*` hotspots and present a menu if more than one is found
4. Handle the rest automatically

---

## How It Works

Both scripts follow the same steps:

```
Detect interface and WiFi tool
        |
Prompt for home WiFi credentials
        |
Scan -> select Chromecast hotspot
        |
Connect to Chromecast hotspot (open network)
        |
Fetch /setup/eureka_info -> extract RSA public key
        |
Encrypt home WiFi password with device public key
        |
POST /setup/connect_wifi  (send encrypted credentials)
POST /setup/save_wifi     (commit with keep_hotspot_until_connected)
        |
Reconnect to home WiFi
        |
Verify Chromecast at /setup/configured_networks
```

### IP Discovery

When `chromecast.local` (mDNS) is unreachable the scripts fall back to the
Chromecast's known static hotspot IP `192.168.255.249`. If that also fails,
`arp-scan` (Bash) or `arp -a` (PowerShell) is used to probe the local subnet.

### Encryption

The Chromecast exposes an RSA public key in PKCS#1 format via `eureka_info`.
The Bash script converts it to PKCS#8 via `openssl` and encrypts with
`pkeyutl`. The PowerShell script parses the DER-encoded key directly using
.NET `RSACryptoServiceProvider` -- no OpenSSL required. Both use PKCS#1 v1.5
padding to match the format the Chromecast setup API expects.

### Windows WiFi Scanning

`netsh wlan show networks` only reads the adapter's background scan cache and
cannot force a fresh scan. The PowerShell script calls `WlanScan()` from
`wlanapi.dll` via P/Invoke to trigger an immediate driver-level scan across all
bands before reading results. This is necessary to reliably detect the
Chromecast's 2.4 GHz hotspot when the controlling machine is already connected
to a 5 GHz network.

### Chromecast API and User-Agent

The Chromecast setup API returns 404 to any POST request that includes a
browser-style `User-Agent` header. PowerShell's `Invoke-RestMethod` adds one
automatically; the script explicitly suppresses it.

---

## License

AGPL v3
