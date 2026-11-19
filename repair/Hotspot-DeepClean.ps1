<#
=====================================================================
 Hotspot-DeepClean.ps1
 For: hotspot was force-started by a boot automation script, then
 broke after a restart and never recovered - even after the script
 was deleted.

 WHY: deleting the script does not undo its side effects:
   1. Ghost "Microsoft Wi-Fi Direct Virtual Adapter" instances
      (yours is #3 - #1 and #2 are ghosts blocking bring-up)
   2. Stale ICS (Internet Connection Sharing) bindings pointing at
      dead adapter GUIDs - each reboot gives the virtual adapter a
      new GUID, so the old binding permanently breaks sharing

 This script:
   0. Verifies no other hotspot app is holding the Wi-Fi radio
   1. Removes ghost Wi-Fi Direct / hosted adapters
   2. Unties ALL ICS sharing bindings (HNetCfg COM)
   3. Resets the ICS registry (scope address + stale backups)
   4. Restarts the tethering service chain
   5. Runs the REAL hotspot test
   6. On success: explains coexistence limits, offers a MINIMAL
      boot task (default: no - your call)

 Keep next to Hotspot-DeepClean.bat and run the .bat as Administrator.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-DeepClean.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Hotspot DeepClean - ghost adapters + stale ICS" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 0. is another hotspot holding the radio? ----------
$busy = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Direct|Hosted' -and $_.Status -eq 'Up' }
if ($busy) {
    Write-Host "!! A virtual hotspot adapter is UP right now:" -ForegroundColor Red
    foreach ($b in $busy) { Write-Host ("   {0} [{1}]" -f $b.InterfaceDescription, $b.Status) }
    Write-Host "That means your 3rd-party hotspot app (or something else) is"
    Write-Host "currently holding the Wi-Fi radio. The Windows hotspot cannot"
    Write-Host "start while another app owns the hotspot role on this adapter."
    Write-Host ""
    Write-Host "1. Fully EXIT the 3rd-party hotspot app (tray icon -> Quit)"
    Write-Host "2. If it installed a service, stop it (services.msc)"
    Write-Host "3. Then come back and run this script again"
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "Radio check: no other hotspot adapter is holding the Wi-Fi. Good."
Write-Host ""

# ---------- 1. remove ghost Wi-Fi Direct / hosted adapters ----------
Write-Host "--- Ghost virtual adapters --------------------------" -ForegroundColor Yellow
$ghosts = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
          Where-Object { $_.Status -eq 'Unknown' -and
                         $_.FriendlyName -match 'Direct|Hosted|Virtual Wi-Fi' }
if ($ghosts) {
    foreach ($g in $ghosts) {
        Write-Host ("  removing ghost: {0}" -f $g.FriendlyName)
        pnputil /remove-device "$($g.InstanceId)" | Out-Null
    }
    Write-Host "  (ghosts removed - they were dead device registrations"
    Write-Host "   left behind by the old boot script)"
} else {
    Write-Host "  no ghost network adapters found (ok)"
}
Write-Host ""

# ---------- 2. untie ALL ICS sharing bindings ----------
Write-Host "--- Resetting ICS sharing bindings ------------------" -ForegroundColor Yellow
try {
    $shr = New-Object -ComObject HNetCfg.HNetShare
    $n = 0
    foreach ($c in $shr.EnumEveryConnection) {
        $pr  = $shr.NetConnectionProps($c)
        $cfg = $shr.INetSharingConfigurationForINetConnection($c)
        $wasPublic = $false; $wasPrivate = $false
        try { if ($cfg.SharingConnectionType -eq 0) { $wasPublic = $true } } catch { }
        try { if ($cfg.SharingConnectionType -eq 1) { $wasPrivate = $true } } catch { }
        try { $cfg.DisableSharing(); $n++ } catch { }
        if ($wasPublic -or $wasPrivate) {
            Write-Host ("  untied: '{0}' (was sharing: {1})" -f $pr.Name, $(if ($wasPublic) {'public/uplink'} else {'private/hotspot'}))
        }
    }
    Write-Host ("  sharing disabled on {0} connection(s) - the hotspot will" -f $n)
    Write-Host "  re-create a clean binding when it starts"
} catch {
    Write-Host ("  ICS COM reset failed: {0}" -f $_.Exception.Message)
}
Write-Host ""

# ---------- 3. ICS registry reset ----------
Write-Host "--- ICS registry reset -------------------------------" -ForegroundColor Yellow
$SvcReg = 'HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess'
reg.exe delete "$SvcReg\Parameters" /v ScopeAddressBackup /f 2>$null | Out-Null
reg.exe delete "$SvcReg\Parameters" /v ScopeAddress /f 2>$null | Out-Null
reg.exe add "$SvcReg\Parameters" /v ScopeAddress /t REG_SZ /d "192.168.137.1" /f | Out-Null
$epoch = Get-Random -Minimum 100 -Maximum 99999
reg.exe add "$SvcReg\Parameters" /v Epoch /t REG_DWORD /d $epoch /f | Out-Null
Write-Host "  - ScopeAddress reset to 192.168.137.1, stale backup removed"
Write-Host ("  - ICS Epoch bumped ({0}) to force a full reconfiguration" -f $epoch)
Write-Host ""

# ---------- 4. restart the tethering chain ----------
Write-Host "--- Restarting the tethering chain ------------------" -ForegroundColor Yellow
foreach ($n in 'icssvc','SharedAccess') { sc.exe stop $n | Out-Null }
sc.exe stop Wlansvc | Out-Null
Start-Sleep -Seconds 3
sc.exe start Wlansvc | Out-Null
Start-Sleep -Seconds 2
foreach ($n in 'Wcmsvc','NlaSvc','SharedAccess','icssvc') { sc.exe start $n | Out-Null }
Start-Sleep -Seconds 3
foreach ($n in @('WlanSvc','Wcmsvc','icssvc','SharedAccess')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { Write-Host ("  {0,-13} {1}" -f $n, $s.Status) }
}
Write-Host ""

# ---------- 5. REAL test ----------
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

Write-Host "--- REAL hotspot test -------------------------------" -ForegroundColor Yellow
$hotspotOn = $false
$mgr = $null
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
if ($null -eq $netProfile) {
    Write-Host "  No internet connection profile - reconnect to Wi-Fi and retry." -ForegroundColor Red
} else {
    try {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile)
        if ([string]$mgr.TetheringOperationalState -ne 'On') {
            try {
                $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
                Write-Host ("  STATUS = {0}" -f [string]$tr.Status)
                if ($tr.AdditionalErrorMessage) { Write-Host ("  message: {0}" -f [string]$tr.AdditionalErrorMessage) }
            } catch { Write-Host ("  tethering API threw: {0}" -f $_.Exception.Message) }
            Start-Sleep -Seconds 3
        }
        if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }
    } catch { Write-Host ("  could not create tethering manager: {0}" -f $_.Exception.Message) }
}
Write-Host ""

# ---------- 6. result ----------
if ($hotspotOn) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  THE HOTSPOT IS ON - the ghost/stale-ICS fix worked" -ForegroundColor Green
    Write-Host ("  SSID     : {0}" -f $ap.Ssid)
    Write-Host ("  Password : {0}" -f $ap.Passphrase)
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT - about running it alongside your 3rd-party app:"
    Write-Host "This Wi-Fi chip has ONE radio. It can be a client + ONE hotspot"
    Write-Host "at a time. The Windows hotspot and your 3rd-party hotspot can"
    Write-Host "NOT run at the same time on this adapter - the second one to"
    Write-Host "start will always fail. If you truly need TWO hotspots at once"
    Write-Host "(e.g. one for the house + one dedicated to the VR headset), the"
    Write-Host "clean solution is a cheap USB Wi-Fi adapter for the second one,"
    Write-Host "or a 5 GHz access point - and for VR streaming the AP is the"
    Write-Host "gold standard anyway."
    Write-Host ""
    $ans = Read-Host "Install the MINIMAL at-logon auto-start? (y/N) [default: no]"
    if ($ans -match '^[yY]') {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $boot = Join-Path $PSScriptRoot 'Hotspot-AutoStart.ps1'
        $bootTxt = @'
# Minimal hotspot auto-start (created by DeepClean) - starts the
# hotspot via the SUPPORTED Windows API only. No ICS binding changes.
$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $PSScriptRoot 'HotspotBootFix.log'
Add-Content $log "$(Get-Date -Format s) auto-start: beginning"
$deadline = (Get-Date).AddSeconds(90)
do {
    Start-Sleep 5
    $p = $null
    try { $p = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch {}
} until ($p -or (Get-Date) -gt $deadline)
if ($p) {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $m = [Windows.RuntimeSystemExtensions]
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
        if ([string]$mgr.TetheringOperationalState -ne 'On') {
            $op = $mgr.StartTetheringAsync()
            $t = $null
            $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
            $task = $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($op))
            $task.Wait(30000) | Out-Null
            Add-Content $log "$(Get-Date -Format s) auto-start: result $($task.Result.Status)"
        } else { Add-Content $log "$(Get-Date -Format s) auto-start: already on" }
    } catch { Add-Content $log "$(Get-Date -Format s) auto-start: error $($_.Exception.Message)" }
} else { Add-Content $log "$(Get-Date -Format s) auto-start: no internet profile" }
'@
        Set-Content -Path $boot -Value $bootTxt -Encoding ASCII
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$boot`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        try {
            Register-ScheduledTask -TaskName 'MobileHotspotAutoStart' -Action $action `
                -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Write-Host "  Installed: 'MobileHotspotAutoStart' at every logon."
            Write-Host "  Unlike your old script, this one ONLY calls the supported"
            Write-Host "  StartTetheringAsync API - it never touches ICS bindings."
            Write-Host "  Remove: Unregister-ScheduledTask MobileHotspotAutoStart"
        } catch {
            Write-Host ("  Could not install the task: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Host "  No auto-start installed. To start it after a reboot, either"
        Write-Host "  flip the toggle in Settings or run this script again."
    }
    Start-Process "ms-settings:network-mobilehotspot"
} else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  Still not starting." -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "We have now cleaned every software layer: services, radios,"
    Write-Host "NCSI, firewall, VPN, drivers, ghost adapters, ICS bindings -"
    Write-Host "and the tethering stack still refuses to come up."
    Write-Host ""
    Write-Host "The remaining damage is inside the stripped image itself, and"
    Write-Host "this install has accumulated three structural amputations:"
    Write-Host "Windows Update UI, the Bluetooth audio service, and now this."
    Write-Host ""
    Write-Host "THE FIX (30-60 min, keeps every app, file and setting):"
    Write-Host "  https://www.microsoft.com/software-download/windows11"
    Write-Host "  -> 'Windows 11 Installation Assistant' - run it, done."
    Write-Host "After it completes, run this DeepClean once more if the hotspot"
    Write-Host "does not come up immediately (it re-creates clean bindings)."
}
Write-Host ""
Read-Host "Press Enter to close"
