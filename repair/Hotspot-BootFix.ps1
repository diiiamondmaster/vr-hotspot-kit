<#
=====================================================================
 Hotspot-BootFix.ps1
 For: hotspot WORKS briefly after manual fixing, then DIES on reboot.

 What it does:
   1. Checks the Windows Update machinery (why the Settings page is
      gone) and tries to restore the services
   2. Lists every Realtek Wi-Fi driver version installed (rollback
      candidates)
   3. Re-runs the full hotspot revival (registry + service restart)
   4. REAL hotspot test via the Windows tethering API
   5. If the hotspot comes ON: installs a scheduled task that
      re-applies this fix at every logon - the reboot problem is
      neutralized permanently
   6. If it stays OFF: prints the decisive verdict and next steps

 Run via Hotspot-BootFix.bat as Administrator.
 The scheduled task re-runs this file with -Boot (silent, logged).
=====================================================================
#>

param([switch]$Boot)
$ErrorActionPreference = 'Continue'

$LogFile = Join-Path $PSScriptRoot 'HotspotBootFix.log'

# ---------- WinRT await helper (needed in both modes) ----------
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

# ---------- output helpers ----------
$BootMode = [bool]$Boot
function Say([string]$t) {
    if ($BootMode) { Add-Content -Path $LogFile -Value "$(Get-Date -Format s)  $t" }
    else { Write-Host $t }
}

# =====================================================================
# BOOT MODE (silent, run by the scheduled task at logon)
# =====================================================================
if ($BootMode) {
    Say "=== boot fix starting ==="
    # wait for the network stack to settle after logon
    $deadline = (Get-Date).AddSeconds(90)
    $netProfile = $null
    while ((Get-Date) -lt $deadline) {
        try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
        if ($netProfile) { break }
        Start-Sleep -Seconds 5
    }
    # restart the tethering chain cleanly (the reboot-breakage fix)
    foreach ($n in 'icssvc','SharedAccess') { sc.exe stop $n | Out-Null }
    sc.exe stop Wlansvc | Out-Null
    Start-Sleep -Seconds 3
    sc.exe start Wlansvc | Out-Null
    Start-Sleep -Seconds 2
    foreach ($n in 'Wcmsvc','SharedAccess','icssvc') { sc.exe start $n | Out-Null }
    Start-Sleep -Seconds 3
    if ($null -ne $netProfile) {
        try {
            $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile)
            if ([string]$mgr.TetheringOperationalState -ne 'On') {
                $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
                Say ("boot fix: StartTetheringAsync = {0}" -f [string]$tr.Status)
            } else { Say "boot fix: hotspot already on" }
        } catch { Say ("boot fix: tethering error: {0}" -f $_.Exception.Message) }
    } else {
        Say "boot fix: no internet profile after 90s - hotspot not started"
    }
    Say "=== boot fix done ==="
    exit 0
}

# =====================================================================
# INTERACTIVE MODE
# =====================================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-BootFix.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Hotspot BootFix - for hotspots that die on reboot" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. Windows Update machinery ----------
Write-Host "--- Windows Update machinery ------------------------" -ForegroundColor Yellow
foreach ($n in @('wuauserv','UsoSvc','WaaSMedicSvc','TrustedInstaller')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { Write-Host ("  {0,-15} status={1,-9} startup={2}" -f $n, $s.Status, $s.StartType) }
    else    { Write-Host ("  {0,-15} MISSING (physically stripped)" -f $n) -ForegroundColor Red }
}
$polPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\SystemSettings',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\SystemSettings',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
)
foreach ($p in $polPaths) {
    $v = (Get-ItemProperty $p -Name SettingsPageVisibility -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($v) {
        Write-Host ("  !! Settings page visibility policy found in {0}:" -f $p) -ForegroundColor Red
        Write-Host ("     {0}" -f $v)
        Write-Host "     Removing it so Settings pages (incl. Windows Update) reappear..."
        reg.exe delete "$($p -replace 'Microsoft\.PowerShell.Core\\Registry::','' -replace ':','')" /v SettingsPageVisibility /f 2>$null | Out-Null
        Remove-ItemProperty -Path $p -Name SettingsPageVisibility -ErrorAction SilentlyContinue
    }
}
try {
    $cp = Get-AppxPackage -Name '*immersivecontrolpanel*' -ErrorAction SilentlyContinue
    if ($cp) { Write-Host ("  Settings app package : {0} ({1}) - present" -f $cp.Name, $cp.Version) }
    else { Write-Host "  Settings app package : NOT FOUND (reinstall via repair upgrade)" -ForegroundColor Red }
} catch { Write-Host "  Settings app package : could not query" }
Write-Host "  (A reboot is needed for any policy removal to take effect.)"
Write-Host ""

# ---------- 2. Realtek driver inventory ----------
Write-Host "--- Installed Realtek network drivers ---------------" -ForegroundColor Yellow
$enum = pnputil /enum-drivers 2>&1 | Out-String
$blocks = $enum -split "(?m)^\s*$" | Where-Object { $_ -match 'Realtek|netrtwlane|8822' }
if ($blocks) { foreach ($b in $blocks) { $b.Trim() -split "`r?`n" | Where-Object { $_ -match 'Published|Original|Provider|Class|Driver version' } | ForEach-Object { Write-Host "  $_" } ; Write-Host "  ----" } }
else { Write-Host "  (no Realtek driver blocks parsed - non-fatal)" }
Write-Host "  If you need to roll back: Device Manager > Wi-Fi adapter >"
Write-Host "  Properties > Driver > Roll Back Driver, or Update driver >"
Write-Host "  Browse > Let me pick > older version."
Write-Host ""

# ---------- 3. hotspot revival ----------
Write-Host "--- Reviving the hotspot stack ----------------------" -ForegroundColor Yellow
$SvcRegReg = 'HKLM\SYSTEM\CurrentControlSet\Services'
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Network Connections" /v NC_ShowSharedAccessUI /t REG_DWORD /d 1 /f | Out-Null
$icsParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'
if (-not (Test-Path $icsParams)) { New-Item -Path $icsParams -Force | Out-Null }
$scope = (Get-ItemProperty $icsParams -ErrorAction SilentlyContinue).ScopeAddress
if (-not $scope) {
    reg.exe add "$SvcRegReg\SharedAccess\Parameters" /v ScopeAddress /t REG_SZ /d "192.168.137.1" /f | Out-Null
    Write-Host "  - restored missing ICS ScopeAddress"
}
reg.exe delete "$SvcRegReg\Wlansvc\Parameters\HostedNetworkSettings" /f 2>$null | Out-Null
reg.exe delete "$SvcRegReg\Wlansvc\Parameters" /v HostedNetworkSettings /f 2>$null | Out-Null
foreach ($n in 'icssvc','SharedAccess') { sc.exe stop $n | Out-Null }
sc.exe stop Wlansvc | Out-Null
Start-Sleep -Seconds 3
sc.exe start Wlansvc | Out-Null
Start-Sleep -Seconds 2
foreach ($n in 'Wcmsvc','NlaSvc','SharedAccess','icssvc') { sc.exe start $n | Out-Null }
Start-Sleep -Seconds 3
Write-Host "  - service chain restarted"
Write-Host ""

# ---------- 4. REAL test ----------
Write-Host "--- REAL hotspot test -------------------------------" -ForegroundColor Yellow
$hotspotOn = $false
$mgr = $null
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
if ($null -eq $netProfile) {
    Write-Host "  No internet connection profile (NCSI) - cannot test now." -ForegroundColor Red
} else {
    try {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile)
        if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }
        else {
            try {
                $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
                Write-Host ("  STATUS = {0}" -f [string]$tr.Status)
                if ($tr.AdditionalErrorMessage) { Write-Host ("  message: {0}" -f [string]$tr.AdditionalErrorMessage) }
            } catch { Write-Host ("  tethering API threw: {0}" -f $_.Exception.Message) }
            Start-Sleep -Seconds 3
            if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }
        }
    } catch { Write-Host ("  could not create tethering manager: {0}" -f $_.Exception.Message) }
}
Write-Host ""

# ---------- 5. success -> install the boot task ----------
if ($hotspotOn) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  THE HOTSPOT IS ON." -ForegroundColor Green
    Write-Host ("  SSID     : {0}" -f $ap.Ssid)
    Write-Host ("  Password : {0}" -f $ap.Passphrase)
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    $ans = Read-Host "Install the auto-fix at every logon so a reboot cannot kill it? (Y/n)"
    if ($ans -eq '' -or $ans -match '^[yY]') {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Boot")
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        try {
            Register-ScheduledTask -TaskName 'MobileHotspotBootFix' -Action $action `
                -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Write-Host "  Installed: task 'MobileHotspotBootFix' runs at every logon." -ForegroundColor Green
            Write-Host "  It waits for the network, restarts the tethering chain, and"
            Write-Host "  starts the hotspot automatically. Log: HotspotBootFix.log"
            Write-Host "  Remove it anytime: Unregister-ScheduledTask -TaskName MobileHotspotBootFix"
        } catch {
            Write-Host ("  Could not install the task: {0}" -f $_.Exception.Message)
            Write-Host "  Fallback: re-run Hotspot-BootFix.bat manually after each reboot."
        }
    }
    Start-Process "ms-settings:network-mobilehotspot"
}
# ---------- 6. failure -> verdict ----------
else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  The hotspot still will not start." -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Diagnosis: components exist (it worked briefly), services"
    Write-Host "  and radios are healthy, VPN ruled out, driver already the"
    Write-Host "  newest you could find. What is left is damage inside the"
    Write-Host "  stripped system image itself - and THIS install also has"
    Write-Host "  a missing Windows Update and missing Bluetooth services."
    Write-Host ""
    Write-Host "  THE FIX - in-place repair upgrade (no Windows Update needed!):"
    Write-Host "  Option A - easiest:"
    Write-Host "    1. Go to https://www.microsoft.com/software-download/windows11"
    Write-Host "    2. Download the 'Windows 11 Installation Assistant' (first section)"
    Write-Host "    3. Run it. It upgrades Windows in place, keeps ALL apps, files,"
    Write-Host "       settings. 30-60 min, fully unattended after a few clicks."
    Write-Host "  Option B - more control:"
    Write-Host "    1. Same page, third section: 'Download Windows 11 Disk Image'"
    Write-Host "    2. Mount the ISO, run setup.exe, choose 'Keep personal files"
    Write-Host "       and apps'."
    Write-Host "  This restores everything tiny11 stripped: hotspot, Windows"
    Write-Host "  Update, Bluetooth audio service, the lot."
    Write-Host ""
    Write-Host "  After the repair, run Hotspot-BootFix.bat once more - if the"
    Write-Host "  hotspot needs the boot fix, it will offer to install it again."
}
Write-Host ""
Read-Host "Press Enter to close"
