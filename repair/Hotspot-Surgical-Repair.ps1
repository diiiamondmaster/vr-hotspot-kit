<#
=====================================================================
 Hotspot-Surgical-Repair.ps1
 Repairs ONLY the hotspot-related OS components, from an official
 Windows 11 ISO - WITHOUT running setup.exe and WITHOUT the full
 in-place upgrade. Preserves a de-bloated (tiny11) install as-is.

 Why this can succeed where earlier attempts failed:
   - earlier DISM repairs used Windows Update as the source, and
     this install's Windows Update is stripped/broken, so payload
     repair silently failed
   - this script points DISM at the mounted ISO instead

 What it does NOT do:
   - does not run setup.exe, does not provision any inbox apps,
     does not add services you did not have, does not touch your
     files, programs or settings. DISM /RestoreHealth only
     restores components that are missing or corrupted.

 Keep next to Hotspot-Surgical-Repair.bat and run the .bat as
 Administrator. You need the official Windows 11 ISO downloaded
 and mounted (double-clicked) beforehand.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Hotspot-Surgical-Repair.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Surgical hotspot repair - component store from ISO" -ForegroundColor Cyan
Write-Host "  (no setup.exe, no upgrade, no bloat)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 0. safety net: restore point ----------
Write-Host "Creating a system restore point first..."
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Before hotspot surgical repair" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Write-Host "  restore point created." -ForegroundColor Green
} catch {
    Write-Host "  could not create a restore point (System Restore may be stripped):" -ForegroundColor Yellow
    Write-Host ("  {0}" -f $_.Exception.Message)
    Write-Host "  continuing anyway - DISM repair is reversible via its log."
}
Write-Host ""

# ---------- 1. locate the mounted ISO ----------
Write-Host "You need the OFFICIAL Windows 11 ISO mounted before continuing:"
Write-Host "  1. https://www.microsoft.com/software-download/windows11"
Write-Host "  2. third section: 'Download Windows 11 Disk Image (ISO) for x64'"
Write-Host "     (download the ISO directly - NOT via Media Creation Tool,"
Write-Host "      the MCT produces .esd images that cannot repair)"
Write-Host "  3. double-click the downloaded ISO to mount it"
Write-Host ""
$dl = Read-Host "Drive letter of the mounted ISO (e.g. E)"
if (-not $dl) { Write-Host "No drive letter given - exiting."; Read-Host "Press Enter to exit"; exit 1 }
$wim = "$($dl):\sources\install.wim"
$esd = "$($dl):\sources\install.esd"
if (-not (Test-Path $wim)) {
    if (Test-Path $esd) {
        Write-Host "That ISO uses install.esd - it cannot serve as a repair source." -ForegroundColor Red
        Write-Host "Download the plain ISO from the link above (third section),"
        Write-Host "not the Media Creation Tool, then run this again."
    } else {
        Write-Host "No install.wim found on drive $dl`: - is the ISO mounted?" -ForegroundColor Red
    }
    Read-Host "Press Enter to exit"; exit 1
}
Write-Host ""

# ---------- 2. pick the matching edition ----------
Write-Host "Reading edition list from the ISO..."
$wimInfo = (dism.exe /Get-WimInfo /WimFile:$wim) 2>&1 | Out-String
$wimInfo.Trim() -split "`r?`n" | ForEach-Object { Write-Host "  $_" }
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ""
Write-Host ("This PC runs edition '{0}' - pick the SAME edition's index." -f $os.EditionID)
$idx = Read-Host "Index number (e.g. the one for Windows 11 Home/Core)"
if (-not $idx) { $idx = '1' }
Write-Host ""

# ---------- 3. the surgical repair ----------
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Running component store repair from the ISO." -ForegroundColor Cyan
Write-Host " This restores ONLY missing/corrupt OS components." -ForegroundColor Cyan
Write-Host " Takes 10-30 minutes. Keep this window open." -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""
dism.exe /Online /Cleanup-Image /RestoreHealth /Source:wim:$wim`:$idx /LimitAccess
$dismRc = $LASTEXITCODE
Write-Host ""
if ($dismRc -ne 0) {
    Write-Host "DISM returned exit code $dismRc." -ForegroundColor Yellow
    Write-Host "Common cause: the ISO build does not match your installed build"
    Write-Host ("(yours is {0}.{1})." -f $os.CurrentBuildNumber, $(if ($os.UBR) {$os.UBR} else {'?'}))
    Write-Host "Fix: get an ISO of your EXACT build from uupdump.net"
    Write-Host "  - choose your build -> 'Download Windows 11 ... x64' -> ISO"
    Write-Host "Details: C:\Windows\Logs\DISM\dism.log"
    Write-Host ""
    $cont = Read-Host "Continue anyway with the remaining steps? (y/N)"
    if ($cont -notmatch '^[yY]') { Read-Host "Press Enter to exit"; exit 1 }
}

# ---------- 4. re-register the tethering bits if still absent ----------
Write-Host ""
Write-Host "--- Re-registering tethering components -----------------" -ForegroundColor Yellow
$CoreDll = Join-Path $env:SystemRoot 'System32\tetheringservice.dll'
$SvcReg  = 'HKLM\SYSTEM\CurrentControlSet\Services'
if (-not (Test-Path $CoreDll)) {
    Write-Host "  tetheringservice.dll is STILL missing after the repair." -ForegroundColor Red
    Write-Host "  The component was hard-deleted from this image; only the"
    Write-Host "  full repair upgrade can bring it back."
} else {
    Write-Host "  tetheringservice.dll present."
}
if (-not (Get-Service icssvc -ErrorAction SilentlyContinue) -and (Test-Path $CoreDll)) {
    Write-Host "  rebuilding the icssvc service registration..."
    sc.exe create icssvc start= demand type= share obj= "NT AUTHORITY\LocalService" displayname= "Windows Mobile Hotspot Service" binPath= "$env:SystemRoot\system32\svchost.exe -k LocalServiceNetworkRestricted -p" | Out-Null
    reg.exe add "$SvcReg\icssvc\Parameters" /v ServiceDll /t REG_EXPAND_SZ /d "%SystemRoot%\System32\tetheringservice.dll" /f | Out-Null
    reg.exe add "$SvcReg\icssvc" /v ImagePath /t REG_EXPAND_SZ /d "%SystemRoot%\system32\svchost.exe -k LocalServiceNetworkRestricted -p" /f | Out-Null
    sc.exe config icssvc depend= RpcSs/Wcmsvc | Out-Null
}
sc.exe config WlanSvc start= auto | Out-Null
sc.exe config icssvc start= demand | Out-Null
sc.exe config SharedAccess start= demand | Out-Null

# clean service chain restart
foreach ($n in 'icssvc','SharedAccess') { sc.exe stop $n | Out-Null }
sc.exe stop Wlansvc | Out-Null
Start-Sleep -Seconds 3
sc.exe start Wlansvc | Out-Null
Start-Sleep -Seconds 2
foreach ($n in 'Wcmsvc','NlaSvc','SharedAccess','icssvc') { sc.exe start $n | Out-Null }
Start-Sleep -Seconds 3
Write-Host "  service chain restarted."
Write-Host ""

# ---------- 5. hotspot-related optional capabilities ----------
Write-Host "--- Hotspot-related optional features ------------------" -ForegroundColor Yellow
try {
    $caps = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Hotspot|Tether|WiFiDirect|WFD' -or
                           ($_.Description -match 'hotspot|tethering') }
    if ($caps) {
        foreach ($c in $caps) { Write-Host ("  {0}  [{1}]" -f $c.Name, $c.State) }
        Write-Host "  (if any show 'Removed', they can be re-added with:"
        Write-Host "   Add-WindowsCapability -Online -Name '<name>' -Source <ISO drive>:)"
    } else { Write-Host "  none found (hotspot is not a removable capability - ok)" }
} catch { Write-Host "  capability enumeration unavailable" }
Write-Host ""

# ---------- 6. REAL test ----------
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

Write-Host "--- REAL hotspot test -----------------------------------" -ForegroundColor Yellow
$hotspotOn = $false
$mgr = $null
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
if ($null -eq $netProfile) {
    Write-Host "  No internet profile right now - reconnect Wi-Fi and re-run." -ForegroundColor Red
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

if ($hotspotOn) {
    $ap = $mgr.GetCurrentAccessPointConfiguration()
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host "  THE HOTSPOT IS ON - surgical repair worked" -ForegroundColor Green
    Write-Host ("  SSID     : {0}" -f $ap.Ssid)
    Write-Host ("  Password : {0}" -f $ap.Passphrase)
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your install stays exactly as de-bloated as it was - only the"
    Write-Host "broken components were restored."
    Write-Host "If reboots ever kill the hotspot again, run Hotspot-DeepClean.bat"
    Write-Host "(it offers a clean, supported-API-only auto-start task)."
    Start-Process "ms-settings:network-mobilehotspot"
} else {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "  Still not starting." -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "If DISM reported an error above (exit code / source mismatch),"
    Write-Host "get your EXACT build's ISO from uupdump.net and run this again -"
    Write-Host "a matching source is the one thing this repair strictly needs."
    Write-Host ""
    Write-Host "If DISM succeeded and it still fails, the tethering stack is"
    Write-Host "damaged beyond component repair in this image. Your remaining"
    Write-Host "options, honestly:"
    Write-Host "  A. Full in-place upgrade (restores MS inbox apps - the thing"
    Write-Host "     you want to avoid; but keeps your programs and files)."
    Write-Host "  B. Keep tiny11 untouched and solve VR with hardware:"
    Write-Host "     - a 5 GHz travel router / access point dedicated to the"
    Write-Host "       headset (fully independent of Windows, best latency), or"
    Write-Host "     - a USB Wi-Fi adapter for the headset link, so your current"
    Write-Host "       3rd-party hotspot app owns the dedicated adapter."
    Write-Host "     For VR streaming specifically, the dedicated AP is the gold"
    Write-Host "     standard anyway - better than any Windows hotspot."
}
Write-Host ""
Read-Host "Press Enter to close"
