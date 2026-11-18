<#
=====================================================================
 Hotspot-Capability-Check.ps1
 Asks Windows DIRECTLY why tethering is refused, using the official
 GetTetheringCapability API, on EVERY connection profile.

 The error 0x83120006 you hit = TetheringCapability value 6 =
 "DisabledDueToUnknownCause". This script gets the same verdict as a
 clean enum value instead of an exception, per profile, and decodes
 it into the exact repair path.

 If ANY profile reports 'Enabled', the script configures that one
 (5 GHz + your SSID/password) and starts the hotspot.

 Keep next to Hotspot-Capability-Check.bat and run the .bat as Admin.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-Capability-Check.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Why is tethering refused? Asking Windows directly" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

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
[Windows.Networking.Connectivity.ConnectionProfile,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null

$decode = @{
    'Enabled'                          = 'tethering ALLOWED on this profile'
    'DisabledByGroupPolicy'            = 'blocked by Group Policy/registry policy - fixable'
    'DisabledByHardwareLimitation'     = 'the Wi-Fi driver/chip refuses AP mode - driver problem'
    'DisabledByOperator'               = 'blocked for the account by a network operator (Wi-Fi: rare)'
    'DisabledBySku'                    = 'blocked by Windows edition/SKU (very rare on Home/Pro)'
    'DisabledByRequiredAppNotInstalled'= 'a REQUIRED TETHERING COMPONENT IS MISSING - tiny11 stripping!'
    'DisabledDueToUnknownCause'        = 'stuck/broken service state (your 0x83120006)'
    'DisabledBySystemCapability'       = 'caller lacks DeviceCapability (app-manifest issue, not you)'
}

# ---------- gather every profile ----------
$profiles = @()
try { $p = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile(); if ($p) { $profiles += $p } } catch { }
try { $all = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles(); if ($all) { foreach ($x in $all) { if ($profiles -notcontains $x) { $profiles += $x } } } } catch { }

if ($profiles.Count -eq 0) {
    Write-Host "No connection profiles at all - connect to Wi-Fi/Ethernet first." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

# ---------- ask the official verdict per profile ----------
$enabledProfile = $null
foreach ($prof in $profiles) {
    $pname = '?'
    try { $pname = $prof.ProfileName } catch { }
    Write-Host ("Profile '{0}':" -f $pname)
    try {
        $cap = Await ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapability($prof)) ([Windows.Networking.NetworkOperators.TetheringCapability])
        $capStr = [string]$cap
        Write-Host ("  capability : {0}  ({1})" -f $capStr, $decode[$capStr]) -ForegroundColor $(if ($capStr -eq 'Enabled') {'Green'} else {'Yellow'})
        $mgr2 = $null
        try {
            $mgr2 = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($prof)
            Write-Host ("  state      : {0}" -f $mgr2.TetheringOperationalState)
        } catch { Write-Host ("  state      : manager creation failed: {0}" -f $_.Exception.Message) }
        if ($capStr -eq 'Enabled' -and -not $enabledProfile) { $enabledProfile = $prof }
    } catch {
        Write-Host ("  capability call itself threw: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ""
}

# ---------- policy locations worth scanning if GroupPolicy shows ----------
Write-Host "--- Quick policy scan (hotspot/Wi-Fi related) ------" -ForegroundColor Yellow
$polKeys = @(
    'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting',
    'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\WiFi\AllowWiFiHotSpotReporting',
    'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connections'
)
foreach ($k in $polKeys) {
    if (Test-Path $k) {
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        $vals = $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
        if ($vals) {
            Write-Host ("  {0}:" -f $k)
            foreach ($v in $vals) { Write-Host ("    {0} = {1}" -f $v.Name, $v.Value) }
        }
    }
}
Write-Host "  (NC_ShowSharedAccessUI was already forced to 1 by earlier scripts)"
Write-Host ""

# ---------- if any profile is Enabled: configure + start ----------
if ($enabledProfile) {
    $pname = '?'
    try { $pname = $enabledProfile.ProfileName } catch { }
    Write-Host "Profile '$pname' reports tethering ENABLED - configuring it..." -ForegroundColor Green
    $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($enabledProfile)

    $ssid = Read-Host "SSID for the hotspot (Enter = 'VR-Link')"
    if (-not $ssid) { $ssid = 'VR-Link' }
    $pass = Read-Host "Password, 8-63 chars (Enter = auto-generated)"
    if (-not $pass) {
        $pass = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
    }
    $cfg = $mgr.GetCurrentAccessPointConfiguration()
    $cfg.Ssid = $ssid
    $cfg.Passphrase = $pass
    try { $cfg.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::FiveGHz } catch { Write-Host "  (band property not settable on this build)" -ForegroundColor DarkGray }
    $cr = Await ($mgr.ConfigureAccessPointAsync($cfg)) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Host ("  configure result: {0}" -f [string]$cr.Status)

    $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    Write-Host ("  start result: {0}" -f [string]$tr.Status)
    Start-Sleep -Seconds 4
    if ([string]$mgr.TetheringOperationalState -eq 'On') {
        $ap = $mgr.GetCurrentAccessPointConfiguration()
        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  HOTSPOT IS ON" -ForegroundColor Green
        Write-Host ("  SSID     : {0}" -f $ap.Ssid)
        Write-Host ("  Password : {0}" -f $ap.Passphrase)
        Write-Host ("  Band     : {0}" -f $ap.Band)
        Write-Host "====================================================" -ForegroundColor Green
        Read-Host "Press Enter to close"; exit 0
    }
}

# ---------- final interpretation ----------
Write-Host ""
Write-Host "=================== VERDICT ========================" -ForegroundColor Cyan
Write-Host "Look at the 'capability' lines above. The value there is"
Write-Host "Windows' own official reason, and each has a defined fix:"
Write-Host ""
Write-Host " DisabledByGroupPolicy -> a registry policy is blocking it;"
Write-Host "   the scan above shows candidates - send them to me."
Write-Host " DisabledByHardwareLimitation -> the 8822CE driver refuses AP"
Write-Host "   mode; only a different driver version can change this."
Write-Host " DisabledByRequiredAppNotInstalled -> tiny11 physically removed"
Write-Host "   a tethering component. The ISO component repair is the fix"
Write-Host "   (36-min download, preserves your de-bloated install)."
Write-Host " DisabledDueToUnknownCause (your 0x83120006) -> broken service"
Write-Host "   state. Try one full REBOOT first (not just service restarts),"
Write-Host "   then re-run this script. If it survives a clean reboot, the"
Write-Host "   component store is damaged -> ISO surgical repair."
Write-Host ""
Write-Host "Send me the capability lines above - that enum value is the"
Write-Host "single most decisive piece of information in this whole saga."
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to close"
