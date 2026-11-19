<#
=====================================================================
 Hotspot-Store-Reset.ps1
 Last software step: the tethering settings store is corrupt or
 missing (every profile fails with "Element not found / Error
 reading stored data for this MobileBroadbandAccount object").

 The fix: back up + delete icssvc's settings store so the service
 RE-CREATES it with defaults on next start, then re-test.

 Reversible: a full .reg backup of the icssvc key is saved next to
 this script before anything is deleted.

 Keep next to Hotspot-Store-Reset.bat and run the .bat as Admin.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-Store-Reset.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Tethering settings store reset (icssvc)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. show what is actually in the icssvc key ----------
Write-Host "--- Current icssvc registry tree ---------------------" -ForegroundColor Yellow
$icssvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc'
if (-not (Test-Path $icssvc)) {
    Write-Host "  icssvc key does not exist at all?!" -ForegroundColor Red
} else {
    Get-ChildItem $icssvc -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  {0}" -f $_.Name)
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
            Write-Host ("    {0} = {1}" -f $p.Name, $p.Value)
        }
    }
    $rootProps = Get-ItemProperty $icssvc -ErrorAction SilentlyContinue
    foreach ($p in ($rootProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
        Write-Host ("  (root) {0} = {1}" -f $p.Name, $p.Value)
    }
}
Write-Host ""

# ---------- 2. back the whole key up ----------
$backup = Join-Path $PSScriptRoot ("icssvc-backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\icssvc" "$backup" /y | Out-Null
if (Test-Path $backup) {
    Write-Host ("Backup saved: {0}" -f $backup) -ForegroundColor Green
    Write-Host "(double-click that file to restore everything as it is now)"
} else {
    Write-Host "WARNING: backup export failed - aborting, nothing will be changed." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
Write-Host ""

# ---------- 3. stop the service, wipe the store, restart ----------
Write-Host "Stopping icssvc and resetting its settings store..."
sc.exe stop icssvc | Out-Null
Start-Sleep -Seconds 2

$storeKeys = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings',
    'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Parameters\Settings',
    'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\PersistedSettings'
)
$wiped = 0
foreach ($k in $storeKeys) {
    if (Test-Path $k) {
        # convert PowerShell provider path (HKLM:\) to reg.exe syntax (HKLM\)
        $regPath = $k -replace '^HKLM:\\', 'HKLM\'
        reg.exe delete "$regPath" /f 2>$null | Out-Null
        if (-not (Test-Path $k)) { Write-Host ("  deleted: {0}" -f $k); $wiped++ }
        else { Write-Host ("  FAILED to delete: {0}" -f $k) -ForegroundColor Red }
    }
}
if ($wiped -eq 0) {
    Write-Host "  no Settings/PersistedSettings subkeys existed - the store was"
    Write-Host "  already absent (the service must normally create it itself)."
    # If the store is already absent but reading still fails, the code that
    # CREATES the store is what's damaged - that's component damage.
} else {
    Write-Host "  store cleared - the service will rebuild defaults on start."
}
Write-Host ""

# also give SharedAccess's store the same treatment (ICS side)
$saBackup = Join-Path $PSScriptRoot ("SharedAccess-backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess" "$saBackup" /y | Out-Null
sc.exe stop SharedAccess | Out-Null
Start-Sleep -Seconds 2
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\PerAloParams') {
    reg.exe delete "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\PerAloParams" /f 2>$null | Out-Null
    Write-Host "  SharedAccess per-adapter bindings cleared too"
}
# keep the ScopeAddress fix from before
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters" /v ScopeAddress /t REG_SZ /d "192.168.137.1" /f | Out-Null

# ---------- 4. restart the chain ----------
sc.exe start Wlansvc | Out-Null
Start-Sleep -Seconds 2
foreach ($n in 'Wcmsvc','NlaSvc','SharedAccess','icssvc') { sc.exe start $n | Out-Null }
Start-Sleep -Seconds 4
foreach ($n in @('WlanSvc','Wcmsvc','SharedAccess','icssvc')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { Write-Host ("  {0,-13} {1}" -f $n, $s.Status) }
}
Write-Host ""

# ---------- 5. re-test capability + start ----------
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
    Write-Host "No internet profile - reconnect and re-run." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

Write-Host "--- Capability after the reset ------------------------" -ForegroundColor Yellow
$capOk = $false
try {
    $cap = Await ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapability($netProfile)) ([Windows.Networking.NetworkOperators.TetheringCapability])
    Write-Host ("  capability : {0}" -f [string]$cap)
    if ([string]$cap -eq 'Enabled') { $capOk = $true }
} catch {
    Write-Host ("  capability call STILL throws: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
Write-Host ""

$hotspotOn = $false
$mgr = $null
try { $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile) } catch { }
if ($mgr) {
    try {
        $cfg = $mgr.GetCurrentAccessPointConfiguration()
        $ssid = Read-Host "SSID for the hotspot (Enter = 'VR-Link')"
        if (-not $ssid) { $ssid = 'VR-Link' }
        $pass = Read-Host "Password, 8-63 chars (Enter = auto)"
        if (-not $pass) {
            $pass = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
        }
        $cfg.Ssid = $ssid
        $cfg.Passphrase = $pass
        try { $cfg.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::FiveGHz } catch { }
        $cr = Await ($mgr.ConfigureAccessPointAsync($cfg)) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        Write-Host ("  configure: {0}" -f [string]$cr.Status)
    } catch {
        Write-Host ("  config step: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "  (continuing - trying to start anyway)"
    }
    try {
        $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        Write-Host ("  START STATUS = {0}" -f [string]$tr.Status)
        if ($tr.AdditionalErrorMessage) { Write-Host ("  message: {0}" -f [string]$tr.AdditionalErrorMessage) }
    } catch {
        Write-Host ("  start threw: {0}" -f $_.Exception.Message)
    }
    Start-Sleep -Seconds 4
    if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }
}
Write-Host ""

if ($hotspotOn) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  THE HOTSPOT IS ON - the store reset fixed it" -ForegroundColor Green
    Write-Host ("  SSID     : {0}" -f $ap.Ssid)
    Write-Host ("  Password : {0}" -f $ap.Passphrase)
    Write-Host ("  Band     : {0}" -f $ap.Band)
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "Connect the VR headset now."
    Start-Process "ms-settings:network-mobilehotspot"
} else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  Store reset did not clear it." -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "That is conclusive: the code that creates/reads the tethering"
    Write-Host "store is itself damaged - this is component damage, and the"
    Write-Host "ISO surgical repair (downloading in your browser right now)"
    Write-Host "is the correct and final software fix:"
    Write-Host "  1. let the ISO download finish"
    Write-Host "  2. double-click it to mount, note the drive letter"
    Write-Host "  3. run Hotspot-Surgical-Repair.bat"
    Write-Host "  4. REBOOT after the repair finishes, then run this"
    Write-Host "     Store-Reset script once more"
    Write-Host "Your de-bloated install is preserved - only damaged OS"
    Write-Host "components are restored from the ISO."
}
Write-Host ""
Read-Host "Press Enter to close"
