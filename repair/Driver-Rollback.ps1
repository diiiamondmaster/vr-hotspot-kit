<#
=====================================================================
 Driver-Rollback.ps1
 Rolls the Realtek Wi-Fi driver back to a previously stored version
 and re-tests the hotspot immediately.

 WHY: the hotspot worked briefly, then died exactly one reboot after
 a 2024 driver was manually installed. That reboot is likely when the
 new driver took over - the old driver's last session was the working
 hotspot session. Rolling back reverses exactly that.

 What it does:
   1. Reads every Realtek network driver stored in Windows
   2. Shows them with dates/versions, marks the ACTIVE one
   3. You pick an older one (or just press Enter for the best one)
   4. Activates it, restarts the Wi-Fi adapter
   5. Runs the REAL hotspot test
   6. Verdict + next steps

 Keep next to Driver-Rollback.bat and run the .bat as Administrator.
=====================================================================
#>

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "ERROR: Not elevated. Run Driver-Rollback.bat as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Wi-Fi driver rollback + hotspot re-test" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- find the Wi-Fi adapter ----------
$wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -like '*802.11*' } | Select-Object -First 1
if (-not $wifi) {
    Write-Host "No physical Wi-Fi adapter found - nothing to roll back." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
Write-Host ("Wi-Fi adapter : {0}" -f $wifi.InterfaceDescription)
Write-Host ("Active driver : v{0}  dated {1}" -f $wifi.DriverVersion, $wifi.DriverDate)

# ---------- which INF is active right now ----------
$netshDrv = (netsh wlan show drivers) 2>&1 | Out-String
$activeInf = [regex]::Match($netshDrv, 'INF file\s*:\s*(\S+\.inf)', 'IgnoreCase').Groups[1].Value
if (-not $activeInf) { $activeInf = $wifi.DriverFileName }
if (-not $activeInf) { $activeInf = '' }
Write-Host ("Active INF    : {0}" -f $activeInf)
Write-Host ""

# ---------- enumerate stored Realtek network drivers ----------
$raw = (pnputil /enum-drivers) 2>&1 | Out-String
$blocks = $raw -split "\r?\n\s*\r?\n"
$drivers = @()
foreach ($b in $blocks) {
    $pub  = [regex]::Match($b, 'Published Name\s*:\s*(\S+)').Groups[1].Value
    $orig = [regex]::Match($b, 'Original Name\s*:\s*(\S+)').Groups[1].Value
    $prov = [regex]::Match($b, 'Provider Name\s*:\s*(.+)').Groups[1].Value.Trim()
    $cls  = [regex]::Match($b, 'Class Name\s*:\s*(\S+)').Groups[1].Value
    $dvm  = [regex]::Match($b, 'Driver Version\s*:\s*(\d{2}/\d{2}/\d{4})\s+([\d\.]+)')
    $date = $dvm.Groups[1].Value
    $ver  = $dvm.Groups[2].Value
    if ($pub -and ($orig -match 'rtwlane|8822' -or $prov -match 'Realtek') -and $cls -match 'Net') {
        $drivers += [pscustomobject]@{
            Inf = $pub; Original = $orig; Version = $ver; Date = $date
        }
    }
}

if ($drivers.Count -eq 0) {
    Write-Host "No stored Realtek network drivers could be parsed." -ForegroundColor Red
    Write-Host "Fallback: Device Manager > Wi-Fi adapter > Properties > Driver"
    Write-Host "tab > 'Roll Back Driver'. If that button is grayed out, use the"
    Write-Host "repair-install path (see end)."
    Read-Host "Press Enter to exit"; exit 1
}

# ---------- show the menu ----------
Write-Host "Realtek Wi-Fi drivers stored on this PC:" -ForegroundColor Yellow
$i = 0
foreach ($d in $drivers) {
    $mark = ''
    if ($d.Inf -ieq $activeInf) { $mark = '   <-- ACTIVE NOW' }
    Write-Host ("  [{0}] {1}  v{2}  ({3}){4}" -f $i, $d.Inf, $d.Version, $d.Date, $mark)
    $i++
}
Write-Host ""

$active = $drivers | Where-Object { $_.Inf -ieq $activeInf }
$others = @($drivers | Where-Object { $_.Inf -ine $activeInf })

if ($others.Count -eq 0) {
    Write-Host "Only ONE Realtek driver exists in the store - the active one." -ForegroundColor Red
    Write-Host "The old driver was deleted when the new one was installed."
    Write-Host ""
    Write-Host "Your options:"
    Write-Host "  1. Device Manager > Wi-Fi adapter > Properties > Driver >"
    Write-Host "     'Roll Back Driver' (works if Windows kept the backup)."
    Write-Host "  2. Download an OLDER driver package from your PC vendor's"
    Write-Host "     support page (look for the Wi-Fi/BT combo driver for your"
    Write-Host "     exact model, 2022-2023 era) and install it."
    Write-Host "  3. Repair install (restores the OS-matched driver too)."
    Read-Host "Press Enter to exit"; exit 0
}

# ---------- pick ----------
Write-Host "Enter the [number] of the OLDER driver to switch to."
$pick = Read-Host "Number (or just press Enter = newest of the others)"
$target = $null
if ($pick -match '^\d+$' -and [int]$pick -lt $drivers.Count) {
    $target = $drivers[[int]$pick]
} else {
    $target = $others | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
}
if ($target.Inf -ieq $activeInf) {
    Write-Host "That IS the active driver - nothing to do."
    Read-Host "Press Enter to exit"; exit 0
}
Write-Host ""
Write-Host ("Switching to: {0}  v{1}  ({2})" -f $target.Inf, $target.Version, $target.Date)
$ok = Read-Host "Proceed? (Y/n)"
if ($ok -match '^[nN]') { Write-Host "Aborted."; Read-Host "Press Enter to exit"; exit 0 }

# ---------- activate the chosen driver ----------
Write-Host ""
Write-Host "Activating the selected driver (30-60 seconds)..."
pnputil /add-driver "$env:SystemRoot\INF\$($target.Inf)" /install
Write-Host ""

# ---------- restart the adapter ----------
Write-Host "Restarting the Wi-Fi adapter..."
Disable-NetAdapter -Name $wifi.Name -Confirm:$false
Start-Sleep -Seconds 5
Enable-NetAdapter -Name $wifi.Name -Confirm:$false
Start-Sleep -Seconds 8
$wifi2 = Get-NetAdapter -Name $wifi.Name -ErrorAction SilentlyContinue
if ($wifi2) {
    Write-Host ("Driver now active: v{0}  dated {1}" -f $wifi2.DriverVersion, $wifi2.DriverDate)
} else {
    Write-Host "Adapter still coming back - waiting a few more seconds..."
    Start-Sleep -Seconds 8
    $wifi2 = Get-NetAdapter -Name $wifi.Name -ErrorAction SilentlyContinue
    if ($wifi2) { Write-Host ("Driver now active: v{0}  dated {1}" -f $wifi2.DriverVersion, $wifi2.DriverDate) }
}
Write-Host ""

# ---------- REAL hotspot test ----------
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
$netProfile = $null
try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }

if ($null -eq $netProfile) {
    Write-Host "No internet profile yet (adapter just restarted) - waiting..."
    Start-Sleep -Seconds 10
    try { $netProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile() } catch { }
}
if ($null -eq $netProfile) {
    Write-Host "Still no internet profile - reconnect to your Wi-Fi and run" 
    Write-Host "Hotspot-BootFix.bat (it only runs the test + boot task parts)." -ForegroundColor Red
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
        if ([string]$mgr.TetheringOperationalState -eq 'On') {
            $hotspotOn = $true
            $ap = $mgr.GetCurrentAccessPointConfiguration()
            Write-Host ""
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host "  THE HOTSPOT IS ON - THE 2024 DRIVER WAS THE CULPRIT" -ForegroundColor Green
            Write-Host ("  SSID     : {0}" -f $ap.Ssid)
            Write-Host ("  Password : {0}" -f $ap.Passphrase)
            Write-Host "====================================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "IMPORTANT: do NOT update this Wi-Fi driver again - not via"
            Write-Host "Device Manager, not via any vendor tool. It is the version"
            Write-Host "that makes your hotspot work."
            Write-Host "If reboots ever kill the hotspot again, run Hotspot-BootFix.bat"
            Write-Host "to install the automatic at-logon fix."
            Start-Process "ms-settings:network-mobilehotspot"
        }
    } catch { Write-Host ("  could not create tethering manager: {0}" -f $_.Exception.Message) }
}

if (-not $hotspotOn) {
    Write-Host ""
    Write-Host "Rollback done but the hotspot still fails." -ForegroundColor Yellow
    Write-Host "That was the last software suspect. This install has now shown:"
    Write-Host "missing Bluetooth audio service, missing Windows Update UI,"
    Write-Host "and a broken tethering bring-up - the image itself is damaged."
    Write-Host ""
    Write-Host "THE FIX - in-place repair upgrade (no Windows Update needed):"
    Write-Host "  1. https://www.microsoft.com/software-download/windows11"
    Write-Host "  2. 'Windows 11 Installation Assistant' (first section) - run it"
    Write-Host "  3. Keeps ALL apps, files, settings; 30-60 min"
    Write-Host "After it finishes, run Hotspot-BootFix.bat once (it also offers"
    Write-Host "the reboot-proof scheduled task if the hotspot needs it)."
}
Write-Host ""
Read-Host "Press Enter to close"
