#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Force an immediate WiFi scan via wlanapi.dll WlanScan().
# netsh wlan show networks only reads the background scan cache -- it cannot
# trigger a scan itself. WlanScan() signals the driver to scan all bands now.
#
# WLAN_INTERFACE_INFO_LIST layout (from wlanapi.h):
#   DWORD dwNumberOfItems  (+0, 4 bytes)
#   DWORD dwIndex          (+4, 4 bytes)
#   WLAN_INTERFACE_INFO[]  (+8, 532 bytes each):
#     GUID   InterfaceGuid          (16 bytes)
#     WCHAR  strInterfaceDescription[256] (512 bytes)
#     DWORD  isState                (4 bytes)
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

Write-Host "[*] Triggering immediate WiFi scan via WlanScan()..."
$scanResult = [WlanScanHelper]::TriggerScan()
Write-Host "    Scan triggered: $scanResult"
Write-Host "    Waiting 5s for results..."
Start-Sleep -Seconds 5

Write-Host "`n--- Raw netsh output ---"
$output = netsh wlan show networks mode=bssid
$output | ForEach-Object { Write-Host "LINE: [$_]" }

Write-Host "`n--- Chromecast-specific matches ---"
$matches = @(
    $output |
    Select-String '^\s*SSID \d+\s+:\s+(Chromecast.+)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
)

if ($matches.Count -eq 0) {
    Write-Host "[!] No Chromecast SSIDs found."
} else {
    $matches | ForEach-Object { Write-Host "    Found: [$_]" }
}
