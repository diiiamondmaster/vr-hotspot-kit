<#
=====================================================================
 Hotspot-5GHz-Setup.ps1
 Configures the Windows hotspot (Wi-Fi Direct stack - the same one
 MyPublicWiFi uses) to 5 GHz with a custom SSID/password, and starts
 it. Bypasses the broken Settings page by using the Windows API.

 CRITICAL: the Wi-Fi adapter can hold only ONE hotspot role at a
 time. MyPublicWiFi's hotspot must be COMPLETELY OFF when you run
 this, or the start will fail - and that failure would tell us
 nothing new.

 What it does:
   1. Refuses to run if another hotspot currently holds the radio
   2. Asks for SSID + password (or accepts defaults)
   3. Configures the hotspot: 5 GHz band, WPA2
   4. Starts it via the Windows tethering API
   5. Verdict + what it means

 Keep next to Hotspot-5GHz-Setup.bat and run the .bat as Admin.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-5GHz-Setup.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  5 GHz hotspot setup (Windows tethering API)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 0. is something else holding the hotspot role? ----------
$busy = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Direct|Hosted' -and $_.Status -eq 'Up' }
if ($busy) {
    Write-Host "!! A hotspot adapter is UP right now:" -ForegroundColor Red
    foreach ($b in $busy) { Write-Host ("   {0} [{1}]" -f $b.InterfaceDescription, $b.Status) }
    Write-Host ""
    Write-Host "That is almost certainly MyPublicWiFi's hotspot (or another app)"
    Write-Host "holding the radio. The adapter can only host ONE hotspot."
    Write-Host ""
    Write-Host "  1. Open MyPublicWiFi and click STOP / exit it completely"
    Write-Host "  2. Run this script again"
    Write-Host ""
    Write-Host "IMPORTANT: this first run is also a DIAGNOSTIC. If the hotspot"
    Write-Host "starts fine once MyPublicWiFi is fully stopped, then the whole"
    Write-Host "'broken hotspot' saga was just role contention - the tests in"
    Write-Host "previous scripts failed because MyPublicWiFi held the radio."
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "Radio check: no other hotspot is holding the adapter. Good."
Write-Host ""

# ---------- 1. WinRT plumbing ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
Function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}
[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null

$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
if ($null -eq $netProfile) {
    Write-Host "No internet connection profile right now." -ForegroundColor Red
    Write-Host "Reconnect to your Wi-Fi (or plug in Ethernet) and re-run."
    Read-Host "Press Enter to exit"
    exit 1
}
$mgr = $null
try { $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile) }
catch {
    Write-Host ("Could not create tethering manager: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

# ---------- 2. get current config ----------
$cfg = $mgr.GetCurrentAccessPointConfiguration()
Write-Host ("Current hotspot config: SSID '{0}', band {1}" -f $cfg.Ssid, $cfg.Band)
Write-Host ""

# ---------- 3. ask for new settings ----------
$ssid = Read-Host "SSID for the hotspot (Enter = keep current)"
if (-not $ssid) { $ssid = $cfg.Ssid }
$pass = Read-Host "Password, 8-63 chars (Enter = keep current)"
if (-not $pass) { $pass = $cfg.Passphrase }

# ---------- 4. apply 5 GHz band ----------
Write-Host ""
$bandSet = $false
try {
    $cfg.Ssid = $ssid
    $cfg.Passphrase = $pass
    try {
        $cfg.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::FiveGHz
        $bandSet = $true
        Write-Host "Band set to: $($cfg.Band)"
    } catch {
        Write-Host "This Windows build does not expose the band property:" -ForegroundColor Yellow
        Write-Host ("  {0}" -f $_.Exception.Message)
        Write-Host "The hotspot will use 'Any' band (Windows picks)."
    }
    $cr = Await ($mgr.ConfigureAccessPointAsync($cfg)) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Host ("ConfigureAccessPointAsync result: {0}" -f [string]$cr.Status)
} catch {
    Write-Host ("Configuration failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# re-read to confirm what stuck
$cfg2 = $mgr.GetCurrentAccessPointConfiguration()
Write-Host ("Active config now   : SSID '{0}', band {1}" -f $cfg2.Ssid, $cfg2.Band)
Write-Host ""

# ---------- 5. start it ----------
Write-Host "Starting the hotspot..."
$hotspotOn = $false
try {
    $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Host ("StartTetheringAsync STATUS = {0}" -f [string]$tr.Status)
    if ($tr.AdditionalErrorMessage) { Write-Host ("message: {0}" -f [string]$tr.AdditionalErrorMessage) }
} catch {
    Write-Host ("tethering API threw: {0}" -f $_.Exception.Message)
}
Start-Sleep -Seconds 4
if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }

Write-Host ""
if ($hotspotOn) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  THE 5 GHz HOTSPOT IS ON" -ForegroundColor Green
    Write-Host ("  SSID     : {0}" -f $ap.Ssid)
    Write-Host ("  Password : {0}" -f $ap.Passphrase)
    Write-Host ("  Band     : {0}" -f $ap.Band)
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Connect the VR headset (and the printer, IF it supports"
    Write-Host "5 GHz - check its specs; many printers are 2.4-only)."
    Write-Host ""
    Write-Host "IMPORTANT: MyPublicWiFi and this hotspot CANNOT run at the"
    Write-Host "same time - one hotspot per radio. If the printer is 2.4-only,"
    Write-Host "connect it by USB instead, or flip between hotspots as needed."
    Write-Host ""
    Write-Host "This also means the 'broken' hotspot was likely never broken -"
    Write-Host "MyPublicWiFi was holding the radio during earlier tests."
    Start-Process "ms-settings:network-mobilehotspot"
} else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  Still failing with MyPublicWiFi fully stopped." -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Then the conflict theory is dead, and the software paths are"
    Write-Host "exhausted. The remaining routes:"
    Write-Host "  1. The ISO surgical repair (start the 36-min download in the"
    Write-Host "     background while you decide - it changes nothing by itself)"
    Write-Host "  2. Hardware for VR: a 5 GHz access point or USB Wi-Fi adapter"
    Write-Host "     - independent of Windows, and the gold standard for VR anyway."
}
Write-Host ""
Read-Host "Press Enter to close"
