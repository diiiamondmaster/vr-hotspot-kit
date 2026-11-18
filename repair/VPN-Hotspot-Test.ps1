<#
=====================================================================
 VPN-Hotspot-Test.ps1
 Tests whether an active VPN (Tailscale/ZeroTier/WireGuard/OpenVPN)
 is what breaks the Windows Mobile Hotspot.

 What it does:
   1. Finds any UP virtual/VPN adapter
   2. Temporarily stops the VPN service + disables the adapter
   3. Runs the REAL hotspot test (Windows tethering API)
   4. If the hotspot comes ON  -> culprit found; VPN is left OFF with
      clear instructions how to turn it back on
   5. If it still fails        -> everything is restored, and the
      answer is the Realtek driver / stripped components

 Keep next to VPN-Hotspot-Test.bat and run the .bat as Administrator.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run VPN-Hotspot-Test.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Hotspot vs VPN test (Tailscale and friends)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- find the VPN ----------
$vpns = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and
                   $_.InterfaceDescription -match 'Tailscale|ZeroTier|WireGuard|OpenVPN|TAP|TUN|VPN' }

$svcMap = @{
    'Tailscale' = 'Tailscale'
    'ZeroTier'  = 'ZeroTierOneService'
    'OpenVPN'   = 'OpenVPNService'
    'WireGuard' = 'WireGuardManager'
}
$stopped = @()
$disabled = @()

if (-not $vpns) {
    Write-Host "No active VPN adapter found right now." -ForegroundColor Yellow
} else {
    foreach ($v in $vpns) {
        Write-Host ("Found VPN adapter: {0} ({1})" -f $v.Name, $v.InterfaceDescription)
        $svcName = $null
        foreach ($k in $svcMap.Keys) { if ($v.InterfaceDescription -match $k) { $svcName = $svcMap[$k] } }
        if ($svcName -and (Get-Service $svcName -ErrorAction SilentlyContinue)) {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                $stopped += $svcName
                Write-Host ("  - stopped service: {0}" -f $svcName)
            } catch { Write-Host ("  - could not stop service {0}: {1}" -f $svcName, $_.Exception.Message) }
        }
        try {
            Disable-NetAdapter -Name $v.Name -Confirm:$false -ErrorAction Stop
            $disabled += $v.Name
            Write-Host ("  - disabled adapter: {0}" -f $v.Name)
        } catch { Write-Host ("  - could not disable adapter: {0}" -f $_.Exception.Message) }
    }
    Start-Sleep -Seconds 3
}
Write-Host ""

# ---------- real hotspot test ----------
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

Write-Host "Testing the hotspot WITHOUT the VPN in the way..." -ForegroundColor Cyan
$hotspotOn = $false
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }

if ($null -eq $netProfile) {
    Write-Host "No internet connection profile - cannot test (NCSI issue)." -ForegroundColor Red
} else {
    try {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile)
        try {
            $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            Write-Host ("StartTetheringAsync STATUS = {0}" -f [string]$tr.Status)
            if ($tr.AdditionalErrorMessage) { Write-Host ("message: {0}" -f [string]$tr.AdditionalErrorMessage) }
        } catch {
            Write-Host ("tethering API threw: {0}" -f $_.Exception.Message)
        }
        Start-Sleep -Seconds 3
        if ([string]$mgr.TetheringOperationalState -eq 'On') {
            $hotspotOn = $true
            $ap = $mgr.GetCurrentAccessPointConfiguration()
            Write-Host ""
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host "  THE HOTSPOT IS ON - THE VPN WAS THE CULPRIT!" -ForegroundColor Green
            Write-Host ("  SSID     : {0}" -f $ap.Ssid)
            Write-Host ("  Password : {0}" -f $ap.Passphrase)
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "The VPN is currently LEFT OFF so your VR headset can use"
            Write-Host "the hotspot right away. To turn the VPN back on later:"
            foreach ($s in $stopped)  { Write-Host ("    net start {0}   (or just reboot)" -f $s) }
            foreach ($a in $disabled) { Write-Host ("    Enable-NetAdapter -Name '{0}'" -f $a) }
            Write-Host ""
            Write-Host "Note: PCVR streaming over the hotspot does not need the VPN."
            Start-Process "ms-settings:network-mobilehotspot"
        }
    } catch {
        Write-Host ("could not create tethering manager: {0}" -f $_.Exception.Message)
    }
}

if (-not $hotspotOn) {
    Write-Host ""
    Write-Host "The hotspot STILL fails without the VPN." -ForegroundColor Yellow
    Write-Host "Restoring the VPN to where it was..."
    foreach ($a in $disabled) { try { Enable-NetAdapter -Name $a -Confirm:$false } catch { } }
    foreach ($s in $stopped)  { try { Start-Service -Name $s } catch { } }
    Write-Host ""
    Write-Host "=> The VPN was NOT the culprit. Next suspects in order:"
    Write-Host "   1. The 2022-08-11 Realtek 8822CE driver (your STATUS = Unknown"
    Write-Host "      is the classic signature of the driver failing to bring up"
    Write-Host "      the Wi-Fi Direct hotspot). Update it:"
    Write-Host "      - Device Manager > your Wi-Fi adapter > Update driver, and"
    Write-Host "      - Windows Update > Advanced options > Optional updates, and/or"
    Write-Host "      - your PC vendor's support page (search '8822CE driver')."
    Write-Host "      Then reboot and run this test again."
    Write-Host "   2. If a NEW driver still fails: the stripped components"
    Write-Host "      (BthAvctpSvc is already missing on this install) mean the"
    Write-Host "      in-place repair upgrade is the clean fix: official ISO,"
    Write-Host "      setup.exe, 'Keep personal files and apps'."
}
Write-Host ""
Read-Host "Press Enter to close"
