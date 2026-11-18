<#
=====================================================================
 Hotspot-Doctor.ps1   (v2 - adds Bluetooth / radio layer)
 Deep diagnosis for a broken Windows 11 Mobile Hotspot (tiny11).

 Wi-Fi hotspot broken + Bluetooth broken on the same machine usually
 means the shared radio layer is the problem, since the Realtek
 RTL8822CE is a Wi-Fi+BT COMBO chip. v2 therefore also checks:
   5. Radio Management Service (RmSvc) - stripped by many tiny11s;
      it arbitrates ALL radios for Windows and the hotspot API
   6. Bluetooth stack services (bthserv etc.) and the Bluetooth
      device tree with PnP error codes
   7. Full radio enumeration (real on/off state of Wi-Fi AND BT)
   Plus the v1 checks:
   1. Base Filtering Engine / Defender Firewall services stripped
   2. NCSI/NLA internet probing disabled
   3. Realtek/Wi-Fi driver state (Wi-Fi Direct capability)
   4. General system state for the report

 Auto-repairs the fixable ones, runs the REAL hotspot test and
 writes everything to HotspotReport.txt next to this script.

 Keep this file next to Hotspot-Doctor.bat and run the .bat.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-Doctor.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Chinese-locale systems output GBK text from netsh/sc
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { }

$Report = Join-Path $PSScriptRoot 'HotspotReport.txt'
if (Test-Path $Report) { Remove-Item $Report -Force }
function Log([string]$t) {
    Write-Host $t
    Add-Content -Path $Report -Value $t -Encoding Default
}

Log "====================================================="
Log " Hotspot diagnostics report v2 - generated $(Get-Date)"
Log "====================================================="
Log ""

# ---------------- basic info ----------------
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Log ("OS        : Windows {0} build {1} edition {2}" -f $os.DisplayVersion, $os.CurrentBuildNumber, $os.EditionID)
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UBR' -ErrorAction SilentlyContinue).UBR
if ($ubr) { Log ("UBR       : $ubr (full build $("{0}.{1}" -f $os.CurrentBuildNumber, $ubr))") }
Log ""

# ---------------- services ----------------
Log "--- Services relevant to the hotspot ---------------"
foreach ($n in @('icssvc','SharedAccess','WlanSvc','Wcmsvc','NlaSvc','BFE','MpsSvc',
                 'RmSvc','bthserv','BthAvctpSvc','DevicesFlowUserSvc')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { Log ("  {0,-20} status={1,-9} startup={2}" -f $n, $s.Status, $s.StartType) }
    else    { Log ("  {0,-20} MISSING" -f $n) }
}
Log ""
if (-not (Get-Service BFE -ErrorAction SilentlyContinue)) {
    Log "  !! BFE (Base Filtering Engine) is MISSING - hotspot sharing is built"
    Log "     on it. Fix: in-place repair upgrade (see end of report)."
} elseif ((Get-Service BFE).Status -ne 'Running') {
    Log "  !! BFE is not running - attempting repair..."
    sc.exe config BFE start= auto | Out-Null
    sc.exe start BFE | Out-Null
    Start-Sleep -Seconds 2
    if ((Get-Service BFE).Status -eq 'Running') { Log "  >> FIXED: BFE is now running." }
    else { Log "  >> FAILED to start BFE." }
}
if (-not (Get-Service MpsSvc -ErrorAction SilentlyContinue)) {
    Log "  !! MpsSvc (Windows Defender Firewall) is MISSING."
    Log "     Fix: in-place repair upgrade (see end of report)."
} elseif ((Get-Service MpsSvc).Status -ne 'Running') {
    Log "  !! MpsSvc is not running - attempting repair..."
    sc.exe config MpsSvc start= auto | Out-Null
    sc.exe start MpsSvc | Out-Null
    Start-Sleep -Seconds 2
    if ((Get-Service MpsSvc).Status -eq 'Running') { Log "  >> FIXED: MpsSvc is now running." }
    else { Log "  >> FAILED to start MpsSvc." }
}
if (-not (Get-Service RmSvc -ErrorAction SilentlyContinue)) {
    Log "  !! RmSvc (Radio Management) is MISSING - this manages ALL radios"
    Log "     (Wi-Fi, Bluetooth, airplane mode). With it gone, Bluetooth AND"
    Log "     the hotspot radio path break together. Fix: repair upgrade."
} elseif ((Get-Service RmSvc).Status -ne 'Running') {
    Log "  !! RmSvc (Radio Management) is not running - attempting repair..."
    sc.exe config RmSvc start= demand | Out-Null
    sc.exe start RmSvc | Out-Null
    Start-Sleep -Seconds 2
    if ((Get-Service RmSvc).Status -eq 'Running') { Log "  >> FIXED: RmSvc is now running." }
    else { Log "  >> FAILED to start RmSvc." }
}
if (-not (Get-Service bthserv -ErrorAction SilentlyContinue)) {
    Log "  !! bthserv (Bluetooth Support) is MISSING - Bluetooth cannot work."
    Log "     Fix: in-place repair upgrade (see end of report)."
} elseif ((Get-Service bthserv).Status -ne 'Running') {
    Log "  !! bthserv is not running - attempting repair..."
    sc.exe config bthserv start= demand | Out-Null
    sc.exe start bthserv | Out-Null
    Start-Sleep -Seconds 2
    if ((Get-Service bthserv).Status -eq 'Running') { Log "  >> FIXED: bthserv is now running." }
    else { Log "  >> FAILED to start bthserv." }
}
Log ""

# ---------------- radio enumeration (Wi-Fi AND Bluetooth) ----------------
Log "--- Radio states (real on/off, via Windows.Radios) --"
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
try {
    [Windows.Devices.Radios.Radio,Windows.Devices.Radios,ContentType=WindowsRuntime] | Out-Null
    $radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    if ($radios.Count -eq 0) {
        Log "  NO RADIOS AT ALL - the radio management layer is dead"
        Log "  (RmSvc missing/broken is the usual cause on tiny11)."
    }
    foreach ($r in $radios) { Log ("  radio: {0,-12} name '{1}'  state={2}" -f $r.Kind, $r.Name, $r.State) }
    $wifiRadio = $radios | Where-Object { $_.Kind.ToString() -eq 'WiFi' } | Select-Object -First 1
    if ($wifiRadio -and $wifiRadio.State.ToString() -ne 'On') {
        try {
            $acc = Await ($wifiRadio.SetStateAsync([Windows.Devices.Radios.RadioState]::On)) ([Windows.Devices.Radios.RadioAccessStatus])
            Log ("  >> tried to switch the Wi-Fi radio on: {0}" -f $acc)
        } catch { Log "  >> could not switch the Wi-Fi radio on programmatically." }
    }
    $btRadio = $radios | Where-Object { $_.Kind.ToString() -eq 'Bluetooth' } | Select-Object -First 1
    if ($btRadio -and $btRadio.State.ToString() -ne 'On') {
        Log "  NOTE: Bluetooth radio exists but is OFF -"
        Log "        toggle Airplane mode / Bluetooth in quick settings once,"
        Log "        or check the physical wireless key on the laptop."
    }
    if (-not $btRadio) { Log "  NOTE: no Bluetooth radio exposed to Windows at all" }
} catch {
    Log ("  radio enumeration FAILED: {0}" -f $_.Exception.Message)
    Log "  -> this itself is a strong RmSvc/radio-layer breakage signal."
}
Log ""

# ---------------- Bluetooth device tree ----------------
Log "--- Bluetooth PnP devices (with error codes) --------"
$btDevices = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue
if (-not $btDevices) { $btDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Bluetooth|蓝牙' } }
if ($btDevices) {
    foreach ($d in $btDevices) {
        $err = ''
        try {
            $wmi = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$($d.InstanceId -replace '\\','\\\\')'" -ErrorAction SilentlyContinue
            if ($wmi -and $wmi.ConfigManagerErrorCode -ne 0) { $err = " ERRORCODE=$($wmi.ConfigManagerErrorCode)" }
        } catch { }
        if ($d.Status -ne 'OK' -or $err -or $d.FriendlyName -match '8822|Realtek') {
            Log ("  [{0}] {1}{2}" -f $d.Status, $d.FriendlyName, $err)
        }
    }
    $btRoot = $btDevices | Where-Object { $_.FriendlyName -match 'Adapter|适配器|8822|Realtek|Bluetooth' } | Select-Object -First 5
    foreach ($d in $btRoot) { Log ("  BT device: {0}  ({1})" -f $d.FriendlyName, $d.InstanceId) }
} else {
    Log "  NO Bluetooth devices in the device tree - BT half of the combo"
    Log "  chip is not enumerated (driver missing or BT stripped)."
}
Log ""

# ---------------- adapters / driver ----------------
Log "--- Wi-Fi adapter and driver ------------------------"
$wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -like '*802.11*' } | Select-Object -First 1
if ($wifi) {
    Log ("  adapter  : {0}" -f $wifi.InterfaceDescription)
    Log ("  state    : {0}  speed {1}" -f $wifi.Status, $wifi.LinkSpeed)
    Log ("  driver   : v{0}  dated {1}" -f $wifi.DriverVersion, $wifi.DriverDate)
} else {
    Log "  NO physical Wi-Fi adapter found!"
}
Log "  (Realtek 8822CE combo driver older than ~2023 is a hotspot+BT suspect;"
Log "   Wi-Fi and Bluetooth come from the SAME driver package on this chip)"
Log ""
Log "--- Hidden / virtual adapters -----------------------"
$virt = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue
$direct = $virt | Where-Object { $_.InterfaceDescription -match 'Direct|Hosted|WFD' }
if ($direct) {
    foreach ($a in $direct) { Log ("  {0}  [{1}]" -f $a.InterfaceDescription, $a.Status) }
} else {
    Log "  no Wi-Fi Direct / hosted adapters present (normal while hotspot is off)"
}
$hyperv = $virt | Where-Object { $_.InterfaceDescription -match 'Hyper-V' }
if ($hyperv) { Log "  NOTE: Hyper-V virtual adapters exist:"; foreach ($a in $hyperv) { Log ("    {0} [{1}]" -f $a.InterfaceDescription, $a.Status) } }
$vpn = $virt | Where-Object { $_.InterfaceDescription -match 'TAP|TUN|VPN|WireGuard|OpenVPN' -and $_.Status -eq 'Up' }
if ($vpn) { Log "  NOTE: an active VPN adapter exists:"; foreach ($a in $vpn) { Log ("    {0}" -f $a.InterfaceDescription) } }
Log ""
Log "--- netsh wlan show drivers (full) ------------------"
$drv = (netsh wlan show drivers) 2>&1 | Out-String
$drv.Trim() -split "`r?`n" | ForEach-Object { Log "  $_" }
Log ""
Log "--- netsh wlan show interfaces ----------------------"
$int = (netsh wlan show interfaces) 2>&1 | Out-String
$int.Trim() -split "`r?`n" | ForEach-Object { Log "  $_" }
Log ""

# ---------------- NCSI / NLA ----------------
Log "--- Internet-connectivity detection (NCSI) ----------"
$ncsiPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
$probe = (Get-ItemProperty $ncsiPath -ErrorAction SilentlyContinue).EnableActiveProbing
Log ("  EnableActiveProbing registry value : {0}  (1 = on)" -f $(if ($null -eq $probe) {'not set'} else {$probe}))
$polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'
if (Test-Path $polPath) {
    $nap = (Get-ItemProperty $polPath -ErrorAction SilentlyContinue).NoActiveProbe
    Log ("  policy NoActiveProbe               : {0}" -f $(if ($null -eq $nap) {'not set'} else {$nap}))
} else { Log "  policy NoActiveProbe               : no policy key (good)" }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
    Log ("  live probe of msftconnecttest.com  : HTTP {0} body '{1}'" -f $r.StatusCode, $r.Content.Trim())
} catch {
    Log ("  live probe of msftconnecttest.com  : FAILED - {0}" -f $_.Exception.Message)
}
$cp = Get-NetConnectionProfile -ErrorAction SilentlyContinue
if ($cp) { foreach ($c in $cp) { Log ("  profile: '{0}' category={1} IPv4={2}" -f $c.Name, $c.NetworkCategory, $c.IPv4Connectivity) } }
else { Log "  NO connection profiles at all (NLA is very broken)" }
if (($null -eq $probe) -or ($probe -eq 0)) {
    Log "  !! NCSI active probing is disabled - re-enabling..."
    reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet" /v EnableActiveProbing /t REG_DWORD /d 1 /f | Out-Null
    reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" /v NoActiveProbe /f 2>$null | Out-Null
    Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    $cp2 = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cp2 -and $cp2.IPv4Connectivity -eq 'Internet') { Log "  >> FIXED: Windows now sees internet on '{0}'." -f $cp2.Name }
    else { Log "  >> probing re-enabled; re-check after a reboot." }
}
Log ""

# ---------------- recent updates ----------------
Log "--- Last installed updates --------------------------"
try {
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 | ForEach-Object {
        Log ("  {0}  {1}" -f $_.HotFixID, $_.InstalledOn)
    }
} catch { Log "  could not enumerate updates" }
Log ""

# ---------------- REAL TEST ----------------
Log "--- REAL hotspot test (Windows tethering API) -------"
[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
if ($null -eq $netProfile) {
    Log "  RESULT: no internet connection profile - hotspot has nothing to share."
    Log "  Windows does not believe you are online (NCSI/NLA issue - see above)."
} else {
    $mgr = $null
    try { $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($netProfile) }
    catch { Log ("  could not create tethering manager: {0}" -f $_.Exception.Message) }
    if ($mgr) {
        Log ("  hotspot state before: {0}" -f $mgr.TetheringOperationalState)
        if ([string]$mgr.TetheringOperationalState -eq 'On') {
            $ap = $mgr.GetCurrentAccessPointConfiguration()
            Log "  RESULT: HOTSPOT IS ON"
            Log ("  SSID {0}   clients {1}" -f $ap.Ssid, $ap.ClientCount)
        } else {
            try {
                $tr = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
                Log ("  StartTetheringAsync STATUS = {0}" -f [string]$tr.Status)
                if ($tr.AdditionalErrorMessage) { Log ("  additional message: {0}" -f [string]$tr.AdditionalErrorMessage) }
            } catch {
                Log ("  tethering API threw: {0}" -f $_.Exception.Message)
            }
            Start-Sleep -Seconds 3
            if ([string]$mgr.TetheringOperationalState -eq 'On') {
                $ap = $mgr.GetCurrentAccessPointConfiguration()
                Log "  RESULT: HOTSPOT IS NOW ON"
                Log ("  SSID {0}   password {1}" -f $ap.Ssid, $ap.Passphrase)
            } else {
                Log "  RESULT: HOTSPOT STILL OFF"
            }
        }
    }
}
Log ""

# ---------------- guidance ----------------
Log "--- What to do next --------------------------------"
Log "  - Radio list shows NO radios / RmSvc missing -> radio layer stripped:"
Log "    in-place repair upgrade (official ISO, setup.exe, 'Keep personal"
Log "    files and apps') is the real fix for both BT and hotspot."
Log "  - Bluetooth device tree shows error codes -> reinstall the RTL8822CE"
Log "    COMBO driver package (covers Wi-Fi + BT together): Device Manager >"
Log "    uninstall device + delete driver for both the Wi-Fi NIC and the BT"
Log "    entry, reboot, then Windows Update > Optional updates, or the latest"
Log "    package from your laptop vendor / Realtek."
Log "  - STATUS 'WiFiDeviceOff' -> same combo-driver fix."
Log "  - 'no internet connection profile' -> reboot, re-run."
Log "  - Missing BFE/MpsSvc/bthserv -> repair upgrade."
Log "  - Build 26300 shipped hotspot regressions - install newest updates."
Log "====================================================="
Log " SEND THIS WHOLE FILE BACK for a targeted fix."
Log "====================================================="

Write-Host ""
Write-Host "Report saved to:" -ForegroundColor Green
Write-Host "  $Report"
Write-Host "It will open in Notepad now - copy EVERYTHING and paste it back."
Start-Process notepad.exe -ArgumentList "`"$Report`""
Read-Host "Press Enter to close"
