<#
=====================================================================
 Restore-MobileHotspot.ps1   (v2 - deep repair)
 Repairs the Mobile Hotspot feature on Windows 11 "tiny11" installs.

 v2 changes (v1 reported success when the icssvc SERVICE was merely
 running, which was a false positive):
  - v2 actually STARTS the hotspot through the Windows API and reads
    the real result code, so the final verdict is the real one.
  - Adds: clean restart of the whole hotspot chain, registry fixes
    (shared-access policy, ICS scope address, stale hosted-network
    blob), WLAN autoconfig reset, Wi-Fi adapter power-cycle, Wi-Fi
    radio check, and a legacy hosted-network fallback with automatic
    connection sharing so you can get devices online immediately.

 Keep this file next to Restore-MobileHotspot.bat and run the .bat
 as Administrator.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

# ---------- make sure we are elevated ----------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host ""
    Write-Host "ERROR: Not elevated. Run Restore-MobileHotspot.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Mobile Hotspot Repair Kit v2 - deep repair (tiny11)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("Detected: Windows {0}  build {1}  edition {2}" -f $os.DisplayVersion, $os.CurrentBuildNumber, $os.EditionID)
Write-Host ""

# ---------- helpers ----------
$SvcRegPs  = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$SvcRegReg = 'HKLM\SYSTEM\CurrentControlSet\Services'
$CoreDll   = Join-Path $env:SystemRoot 'System32\tetheringservice.dll'

function Get-Svc([string]$n) { Get-Service -Name $n -ErrorAction SilentlyContinue }
function Test-DllPresent  { Test-Path $CoreDll }
function Test-IcssvcEntry { ($null -ne (Get-Svc 'icssvc')) }

function Get-WiFiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -like '*802.11*' } | Select-Object -First 1
}

# ---------- WinRT await helper (Windows PowerShell 5.1 compatible) ----------
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

# ---------- diagnosis ----------
function Show-Diagnosis {
    Write-Host "--- Current state -----------------------------------" -ForegroundColor Yellow
    foreach ($n in @('icssvc','SharedAccess','WlanSvc','Wcmsvc','NlaSvc')) {
        $s = Get-Svc $n
        if ($s) { Write-Host ("  {0,-13} status={1,-9} startup={2}" -f $n, $s.Status, $s.StartType) }
        else    { Write-Host ("  {0,-13} MISSING" -f $n) -ForegroundColor Red }
    }
    if (Test-DllPresent) { Write-Host "  tetheringservice.dll present: yes" }
    else { Write-Host "  tetheringservice.dll present: NO" -ForegroundColor Red }
    $w = Get-WiFiAdapter
    if ($w) {
        Write-Host ("  Wi-Fi adapter : {0}" -f $w.InterfaceDescription)
        Write-Host ("  driver        : v{0}  ({1})" -f $w.DriverVersion, $w.DriverDate)
    } else { Write-Host "  Wi-Fi adapter : none detected" -ForegroundColor Red }
    $cp = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cp) { Write-Host ("  uplink profile: {0}  (IPv4: {1})" -f $cp.Name, $cp.IPv4Connectivity) }
    else { Write-Host "  uplink profile: NONE - Windows sees no connected network!" -ForegroundColor Red }
    Write-Host "  virtual Wi-Fi adapters present right now:"
    $va = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
          Where-Object { $_.InterfaceDescription -match 'Direct|Hosted' }
    if ($va) { foreach ($a in $va) { Write-Host ("    {0}  [{1}]" -f $a.InterfaceDescription, $a.Status) } }
    else { Write-Host "    none (Wi-Fi Direct adapters appear only when a hotspot starts)" }
    try {
        $hf = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3
        foreach ($h in $hf) { Write-Host ("  update: {0} ({1})" -f $h.HotFixID, $h.InstalledOn) }
    } catch { }
    Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
}

Show-Diagnosis

# =====================================================================
# STEP 0 - structural repair: files and service registration (v1 logic)
# =====================================================================
if (-not (Test-DllPresent)) {
    Write-Host "STEP 0: tetheringservice.dll missing - repairing system files (10-25 min)..." -ForegroundColor Cyan
    sfc.exe /scannow
    dism.exe /Online /Cleanup-Image /RestoreHealth
}
if (-not (Test-IcssvcEntry) -and (Test-DllPresent)) {
    Write-Host "STEP 0: rebuilding the icssvc service registration..." -ForegroundColor Cyan
    sc.exe create icssvc start= demand type= share obj= "NT AUTHORITY\LocalService" displayname= "Windows Mobile Hotspot Service" binPath= "$env:SystemRoot\system32\svchost.exe -k LocalServiceNetworkRestricted -p"
    reg.exe add "$SvcRegReg\icssvc\Parameters" /v ServiceDll /t REG_EXPAND_SZ /d "%SystemRoot%\System32\tetheringservice.dll" /f | Out-Null
    reg.exe add "$SvcRegReg\icssvc" /v ImagePath /t REG_EXPAND_SZ /d "%SystemRoot%\system32\svchost.exe -k LocalServiceNetworkRestricted -p" /f | Out-Null
    reg.exe add "$SvcRegReg\icssvc" /v Start /t REG_DWORD /d 3 /f | Out-Null
    sc.exe config icssvc depend= RpcSs/Wcmsvc
}
sc.exe config WlanSvc      start= auto   | Out-Null
sc.exe config icssvc       start= demand | Out-Null
sc.exe config SharedAccess start= demand | Out-Null

# =====================================================================
# STEP 1 - registry-level fixes known to break hotspot SETUP even when
#          every service is running (your symptom)
# =====================================================================
Write-Host "STEP 1: applying hotspot-related registry fixes..." -ForegroundColor Cyan

# 1a. Policy can hide/block the shared-access UI (common in stripped images)
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Network Connections" /v NC_ShowSharedAccessUI /t REG_DWORD /d 1 /f | Out-Null
Write-Host "  - ensured the shared-access UI policy allows the hotspot"

# 1b. ICS needs its private-side address to exist
$icsParams = "$SvcRegPs\SharedAccess\Parameters"
if (-not (Test-Path $icsParams)) { New-Item -Path $icsParams -Force | Out-Null }
$scope = (Get-ItemProperty $icsParams -ErrorAction SilentlyContinue).ScopeAddress
if (-not $scope) {
    reg.exe add "$SvcRegReg\SharedAccess\Parameters" /v ScopeAddress /t REG_SZ /d "192.168.137.1" /f | Out-Null
    Write-Host "  - restored missing ICS ScopeAddress (192.168.137.1)"
}

# 1c. Stale hosted-network blob can stop the WLAN stack re-provisioning APs
if (Test-Path "$SvcRegPs\Wlansvc\Parameters\HostedNetworkSettings") {
    reg.exe delete "$SvcRegReg\Wlansvc\Parameters\HostedNetworkSettings" /f 2>$null | Out-Null
    Write-Host "  - reset stale hosted-network settings"
}
reg.exe delete "$SvcRegReg\Wlansvc\Parameters" /v HostedNetworkSettings /f 2>$null | Out-Null

# =====================================================================
# STEP 2 - clean restart of the entire hotspot chain (clears stuck state)
# =====================================================================
Write-Host "STEP 2: clean restart of the hotspot service chain..." -ForegroundColor Cyan
foreach ($n in 'icssvc','SharedAccess') {
    if (Get-Svc $n) { sc.exe stop $n | Out-Null }
}
if (Get-Svc 'Wlansvc') {
    sc.exe stop Wlansvc | Out-Null
    Start-Sleep -Seconds 3
    sc.exe start Wlansvc | Out-Null
    Start-Sleep -Seconds 2
}
if (Get-Svc 'NlaSvc') { sc.exe start NlaSvc | Out-Null }
foreach ($n in 'Wcmsvc','SharedAccess','icssvc') {
    if (Get-Svc $n) { sc.exe start $n | Out-Null }
}
Start-Sleep -Seconds 2
foreach ($n in @('WlanSvc','Wcmsvc','icssvc','SharedAccess')) {
    $s = Get-Svc $n
    if ($s) { Write-Host ("  {0,-13} {1}" -f $n, $s.Status) }
}
Write-Host ""

# =====================================================================
# STEP 3 - WLAN autoconfig, Wi-Fi adapter power-cycle, Wi-Fi radio
# =====================================================================
$wifi = Get-WiFiAdapter
if ($wifi) {
    Write-Host "STEP 3: resetting the Wi-Fi adapter path..." -ForegroundColor Cyan
    netsh wlan set autoconfig enabled=yes interface="$($wifi.Name)" | Out-Null
    Write-Host "  - power-cycling the Wi-Fi adapter (Wi-Fi drops for a few seconds)"
    Disable-NetAdapter -Name $wifi.Name -Confirm:$false
    Start-Sleep -Seconds 4
    Enable-NetAdapter -Name $wifi.Name -Confirm:$false
    Start-Sleep -Seconds 6
}
try {
    [Windows.Devices.Radios.Radio,Windows.Devices.Radios,ContentType=WindowsRuntime] | Out-Null
    $radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    $wifiRadio = $radios | Where-Object { $_.Kind.ToString() -eq 'WiFi' } | Select-Object -First 1
    if ($wifiRadio) {
        Write-Host ("  - Wi-Fi radio state: {0}" -f $wifiRadio.State)
        if ($wifiRadio.State.ToString() -ne 'On') {
            try {
                $acc = Await ($wifiRadio.SetStateAsync([Windows.Devices.Radios.RadioState]::On)) ([Windows.Devices.Radios.RadioAccessStatus])
                Write-Host ("  - tried to switch the radio on: {0}" -f $acc)
            } catch {
                Write-Host "  - could not switch the radio programmatically;"
                Write-Host "    turn Wi-Fi on via the quick-settings panel (network icon)."
            }
        }
    }
} catch {
    Write-Host "  - radio check skipped: $($_.Exception.Message)"
}
Write-Host ""

# =====================================================================
# STEP 4 - THE REAL TEST: actually start the hotspot via the Windows API
# =====================================================================
Write-Host "===================== REAL TEST ====================" -ForegroundColor Cyan
$hotspotOn = $false
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }

if ($null -eq $netProfile) {
    Write-Host "Windows reports NO internet connection profile." -ForegroundColor Red
    Write-Host "The hotspot has nothing to share. If you ARE online right now, this"
    Write-Host "usually means NCSI/NLA is disabled (common with tiny11/privacy"
    Write-Host "tweaks). The legacy fallback below can still work."
} else {
    $mgr = $null
    try {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile)
    } catch {
        Write-Host ("Could not create the tethering manager: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    if ($mgr) {
        Write-Host ("Hotspot state before: {0}" -f $mgr.TetheringOperationalState)
        if ([string]$mgr.TetheringOperationalState -eq 'On') {
            $hotspotOn = $true
        } else {
            $decode = @{
                'Success'                = 'started fine'
                'Unknown'                = 'Windows could not bring up the Wi-Fi hotspot path (Wi-Fi Direct / driver problem)'
                'WiFiDeviceOff'          = 'the Wi-Fi device/radio is off or the driver is dead'
                'MobileHotspotIsOn'      = 'already on'
                'BluetoothDeviceOff'     = 'reported a Bluetooth transport problem (Wi-Fi was requested)'
                'CellDataOff'            = 'reported cellular-off (unexpected for Wi-Fi)'
                'CellNotEntitled'        = 'cellular entitlement problem (unexpected for Wi-Fi)'
                'EntitlementCheckFailed' = 'entitlement/SKU policy blocked it'
                'MissingPersona'         = 'the hotspot persona is missing from this install (tiny11 stripping)'
            }
            for ($try = 1; $try -le 2 -and -not $hotspotOn; $try++) {
                try {
                    $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
                    $status = [string]$tr.Status
                    $msg    = [string]$tr.AdditionalErrorMessage
                    Write-Host ("Attempt {0}: STATUS = {1}" -f $try, $status)
                    if ($msg) { Write-Host ("        message: {0}" -f $msg) }
                    if ($decode.ContainsKey($status)) { Write-Host ("        meaning: {0}" -f $decode[$status]) }
                } catch {
                    Write-Host ("Attempt {0}: the tethering API threw: {1}" -f $try, $_.Exception.Message)
                }
                Start-Sleep -Seconds 3
                if ([string]$mgr.TetheringOperationalState -eq 'On') { $hotspotOn = $true }
            }
        }
        if ($hotspotOn) {
            $ap = $mgr.GetCurrentAccessPointConfiguration()
            Write-Host ""
            Write-Host "REAL RESULT: THE HOTSPOT IS ON." -ForegroundColor Green
            Write-Host ("  SSID     : {0}" -f $ap.Ssid)
            Write-Host ("  Password : {0}" -f $ap.Passphrase)
            Start-Process "ms-settings:network-mobilehotspot"
        } else {
            Write-Host "REAL RESULT: the hotspot is still OFF (see STATUS above)." -ForegroundColor Red
            Write-Host "That STATUS line is the true root cause. Note it and send it"
            Write-Host "back if you want a targeted follow-up fix."
        }
    }
}

# =====================================================================
# STEP 5 - fallback: legacy hosted-network hotspot + automatic sharing
# =====================================================================
$fallbackUp = $false
if (-not $hotspotOn) {
    Write-Host ""
    Write-Host "===================== FALLBACK =====================" -ForegroundColor Cyan
    $ans = Read-Host "Set up the LEGACY hotspot right now so you can get online? (Y/n)"
    if ($ans -eq '' -or $ans -match '^[yY]') {
        $before = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
        netsh wlan set hostednetwork mode=allow | Out-Null
        Start-Sleep -Seconds 2
        $ha = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
              Where-Object { $before -notcontains $_.InterfaceGuid } | Select-Object -First 1
        if (-not $ha) {
            $ha = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                  Where-Object { $_.InterfaceDescription -like '*Hosted*' -or $_.InterfaceDescription -like '*承载*' } |
                  Select-Object -First 1
        }
        if (-not $ha) {
            Write-Host "This Wi-Fi driver does not support the legacy hosted network either." -ForegroundColor Red
        } else {
            $keyFile = Join-Path $PSScriptRoot 'FallbackHotspot.txt'
            $ssid = $null; $key = $null
            if (Test-Path $keyFile) {
                $lines = @(Get-Content $keyFile)
                if ($lines.Count -ge 2) { $ssid = [string]$lines[0]; $key = [string]$lines[1] }
            }
            if (-not $ssid) { $ssid = 'TinyFix-Hotspot' }
            if (-not $key) {
                $key = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
            }
            Set-Content -Path $keyFile -Value $ssid,$key
            netsh wlan set hostednetwork mode=allow ssid=$ssid key=$key | Out-Null
            $out = netsh wlan start hostednetwork 2>&1
            Write-Host ("netsh says: {0}" -f (($out | Select-Object -Last 1)))
            Start-Sleep -Seconds 4
            $ha = Get-NetAdapter -ErrorAction SilentlyContinue |
                  Where-Object { $_.InterfaceGuid -eq $ha.InterfaceGuid } | Select-Object -First 1
            if ($ha -and $ha.Status -eq 'Up') {
                # share the uplink onto the hotspot adapter (ICS)
                $upGuid = $null
                try {
                    if ($null -ne $netProfile -and $null -ne $netProfile.NetworkAdapter) {
                        $upGuid = ([string]$netProfile.NetworkAdapter.NetworkAdapterId).Trim('{}')
                    }
                } catch { }
                if (-not $upGuid) {
                    $defRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                                Sort-Object RouteMetric | Select-Object -First 1
                    if ($defRoute) {
                        $upAd = Get-NetAdapter -InterfaceIndex $defRoute.InterfaceIndex -ErrorAction SilentlyContinue
                        if ($upAd) { $upGuid = $upAd.InterfaceGuid.Trim('{}') }
                    }
                }
                try {
                    $shr = New-Object -ComObject HNetCfg.HNetShare
                    foreach ($c in $shr.EnumEveryConnection) {
                        $pr  = $shr.NetConnectionProps($c)
                        $cfg = $shr.INetSharingConfigurationForINetConnection($c)
                        $g = ([string]$pr.Guid).Trim('{}')
                        if ($upGuid -and $g -eq $upGuid) {
                            try { $cfg.DisableSharing() } catch { }
                            try { $cfg.EnableSharing(0); Write-Host ("  - sharing uplink connection: {0}" -f $pr.Name) }
                            catch { Write-Host "  - could not share the uplink: $($_.Exception.Message)" }
                        }
                        if ($g -eq $ha.InterfaceGuid.Trim('{}')) {
                            try { $cfg.DisableSharing() } catch { }
                            try { $cfg.EnableSharing(1); Write-Host ("  - hotspot side connection : {0}" -f $pr.Name) }
                            catch { Write-Host "  - could not mark the hotspot side: $($_.Exception.Message)" }
                        }
                    }
                } catch {
                    Write-Host "  - ICS configuration failed: $($_.Exception.Message)"
                }
                $fallbackUp = $true
                Write-Host ""
                Write-Host "FALLBACK HOTSPOT IS UP." -ForegroundColor Green
                Write-Host ("  SSID     : {0}" -f $ssid)
                Write-Host ("  Password : {0}" -f $key)
                Write-Host "  Connect your other devices to that network now."
                Write-Host "  Note: the legacy hotspot turns off after a reboot."
                $batPath = Join-Path $PSScriptRoot 'Start-Hotspot-Fallback.bat'
                $batTxt = "@echo off`r`nrem Starts the legacy fallback hotspot (created by the Repair Kit)`r`nnetsh wlan start hostednetwork`r`necho Hotspot starting - SSID/password are in FallbackHotspot.txt`r`npause`r`n"
                Set-Content -Path $batPath -Value $batTxt
                Write-Host "  Created Start-Hotspot-Fallback.bat to turn it on again later"
                Write-Host "  (right-click, Run as administrator)."
                Write-Host "  To stop it: netsh wlan stop hostednetwork"
            } else {
                Write-Host "The legacy hosted network failed to start:" -ForegroundColor Red
                $out | ForEach-Object { Write-Host "  $_" }
            }
        }
    }
}

# =====================================================================
# FINAL STATUS (honest)
# =====================================================================
Write-Host ""
Write-Host "=================== FINAL STATUS ===================" -ForegroundColor Cyan
if ($hotspotOn) {
    Write-Host " Mobile hotspot (modern, Wi-Fi Direct) : ON - working" -ForegroundColor Green
} else {
    Write-Host " Mobile hotspot (modern, Wi-Fi Direct) : OFF" -ForegroundColor Red
}
if ($fallbackUp) {
    Write-Host " Legacy fallback hotspot               : UP - usable now" -ForegroundColor Green
}
if (-not $hotspotOn) {
    Write-Host ""
    if ($fallbackUp) {
        Write-Host "You can get online with the fallback above. For the PERMANENT fix:"
    } else {
        Write-Host "Nothing is working yet. Do these next, in order:"
    }
    Write-Host " 1. Reboot once, then run this kit again (fresh service state)."
    Write-Host " 2. Update the Realtek 8822CE driver (Device Manager > Network"
    Write-Host "    adapters > Realtek 8822CE > Update driver, or Windows Update >"
    Write-Host "    Advanced options > Optional updates)."
    Write-Host " 3. Install the newest cumulative update - some 26xxx builds shipped"
    Write-Host "    with hotspot regressions that later updates fixed."
    Write-Host " 4. Guaranteed: in-place repair upgrade (keeps apps and data):"
    Write-Host "    - Official ISO for your edition (Core = Windows 11 Home):"
    Write-Host "      https://www.microsoft.com/software-download/windows11"
    Write-Host "    - Mount it, run setup.exe, pick 'Keep personal files and apps'."
    Write-Host " 5. Send back the REAL TEST 'STATUS =' lines for a targeted fix."
}
Write-Host "=====================================================" -ForegroundColor Cyan
Read-Host "Press Enter to close"
