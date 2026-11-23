<#
=====================================================================
 VR-Hotspot-Studio.ps1  v2.3.0
 A standalone Wi-Fi hotspot app that does NOT depend on the Windows
 Mobile Hotspot (icssvc/tethering) stack at all.

 HOW IT WORKS (the important part):
   It uses the WiFiDirectAdvertisementPublisher WinRT API in
   Autonomous Group Owner mode with LegacySettings - the same
   mechanism third-party hotspot apps (like MyPublicWiFi) use on
   modern machines where the legacy "hosted network" is gone.
   This path lives in wlansvc / Wi-Fi Direct, NOT in icssvc, so a
   broken tethering store (error 0x83120006 / "Element not found")
   does not affect it.

 Two sharing modes:
   SHARED MODE (default): shares your uplink through Windows ICS
     (NAT 192.168.137.x, Windows' own DHCP).
   ROUTER MODE (advanced): the app itself runs NAT (New-NetNat) and
     a built-in DHCP server with per-MAC static IP reservations -
     ideal for printers that need a fixed address. Reservations can
     be added or removed while the hotspot is running. The hotspot
     subnet is YOUR choice now: any private /24 (10.x, 172.16-31.x,
     192.168.x) via the "Hotspot IP" box; a start-time check refuses
     subnets that collide with the uplink.

v2.3.0:
   - Hotspot IP field: Router mode is no longer locked to
     192.168.137.x - pick any private /24.
   - "Latency + bandwidth" card: a visible Track dropdown chooses
     which connected device the graph follows (the right-click menu
     still works too), and a second strip under the latency graph
     shows live hotspot throughput - to devices / from devices in
     Mbps with session totals, from the adapter counters.
   - DPI-aware rendering: the whole layout scales on 125-150%
     displays, and labels sit above their input fields, so text no
     longer overlaps the text boxes on scaled screens.

 CONNECTED DEVICES (v2.2.0 rework):
   A background tracker merges the ARP/neighbor table, DHCP leases
   and a 1-per-second keepalive ping into one stable device table,
   so the list no longer flickers when a device connects, keeps
   updating while VR mode is on, and devices only disappear after
   a grace period (not the moment an ARP entry flaps). The same
   pings feed the latency graph - which now also works in Router
   mode and can track ANY device (right-click a device and pick
   "Watch latency"), not just whatever happened to be row one.
   Double-click a connected device (or right-click it) to pin a
   static IP reservation for it - no MAC typing.

 VR MODE (checkbox, on by default): pauses Windows' background Wi-Fi
   scans while the hotspot runs - that scanning is what causes the
   every-few-minutes dropout in VR. Scans resume automatically when
   the hotspot stops, the app closes, or on the next launch after a
   crash (vrmode.flag + a temp-folder fallback). Power saving on the
   Wi-Fi adapters is ALWAYS disabled while the hotspot runs - no
   toggle, by design (Realtek power saving causes micro-stutters).

 About 5 GHz: this API does not expose a band switch. The hotspot
   channel follows your uplink connection's channel. Connect the PC
   to a 5 GHz network (like your current ch161) and the hotspot runs
   5 GHz too. The app displays the live channel.

 Requirements: run as Administrator. Only ONE hotspot can hold the
   Wi-Fi radio - stop MyPublicWiFi etc. before starting this one.

 Testing: the script has a self-test hook (VRHS_SELFTEST=1) that
   skips elevation and the GUI so the core logic (settings,
   reservations, VR-mode flag handling, the DHCP server and the
   client tracker, including a simulated-neighbor mode) can be
   exercised by an automated test harness on any machine.
=====================================================================
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$SelfTest   = ($env:VRHS_SELFTEST -eq '1')
$AppVersion = '2.3.0'

# NetAdapter cmdlets are missing on some stripped images - detect once
# so the app can degrade with a clear message instead of dying at load
$script:HasNetAdapter = [bool](Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)
# Router mode also needs the NetTCPIP cmdlets (Get-/New-NetIPAddress,
# New-NetNat); Shared mode does not. Detected once for the same reason.
$script:HasNetTcpIp = [bool](Get-Command -Name Get-NetIPAddress -ErrorAction SilentlyContinue)

# =====================================================================
# script location - MUST be resolved before anything that uses it
# (v2.0.0 bug: $VrFlagFile was built from $ScriptDir two lines
#  before $ScriptDir existed, causing the Join-Path null errors)
# =====================================================================
if ($PSScriptRoot)                            { $ScriptDir = $PSScriptRoot }
elseif ($MyInvocation.MyCommand.Path)         { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else                                          { $ScriptDir = (Get-Location).Path }
$SettingsFile = Join-Path $ScriptDir 'hotspot-settings.json'
$ResvFile     = Join-Path $ScriptDir 'reservations.csv'
$VrFlagFile   = Join-Path $ScriptDir 'vrmode.flag'
$VrFlagAlt    = Join-Path ([System.IO.Path]::GetTempPath()) 'vrhs-vrmode.flag'

# =====================================================================
# state
# =====================================================================
$script:Pub         = $null
$script:VAdapter    = $null      # the Wi-Fi Direct virtual adapter
$script:DhcpRun     = $null      # runspace for router mode
$script:DhcpHandle  = $null
$script:ResvCache   = $null      # reservations loaded from CSV
$script:ScanRun     = $null      # runspace for the client tracker
$script:ScanHandle  = $null
$sync               = [hashtable]::Synchronized(@{})
$sync.Log           = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.Leases        = [hashtable]::Synchronized(@{})       # mac (colon) -> ip (DHCP server writes)
$sync.LeaseList     = @()                                    # immutable lease snapshot published by the DHCP server
$sync.Hostnames     = [hashtable]::Synchronized(@{})       # mac (colon) -> DHCP hostname (option 12)
$sync.Reservations  = @{}                                   # macKey (bare) -> reserved ip
$sync.Stop          = $false
# client tracker state (written by the scan runspace, read by the GUI)
$sync.Clients       = @()                                    # immutable snapshot published each cycle
$sync.PingHist      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.PingTarget    = $null
$sync.TargetMac     = $null
$sync.TargetName    = $null
$sync.TargetLocked  = $false
$sync.StopScan      = $false
$sync.ScanIfIndex   = 0
$sync.RouterMode    = $false
$sync.GraceOnline   = 0        # 0 = built-in default (12 s)
$sync.GraceRemove   = 0        # 0 = built-in default (45 s)
# test hooks (sim mode lets a harness drive fake neighbors/pings)
$sync.Sim           = $false
$sync.SimNeighbors  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.SimPing       = [hashtable]::Synchronized(@{})
# bandwidth history (Mbps per cycle; -1 = no sample) + session totals,
# sampled from the hotspot adapter counters by the client tracker
$sync.BwHistR       = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.BwHistT       = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.BwOk          = $false     # true once a counter sample succeeded
$sync.BwFail        = $false     # true when adapter counters are unavailable
$sync.BwTotalR      = [long]0    # session total bytes, hotspot RX (from devices)
$sync.BwTotalT      = [long]0    # session total bytes, hotspot TX (to devices)
$sync.BwIfName      = ''         # adapter the tracker samples counters on
$sync.BwIfIndex     = 0          # its interface index (hidden adapters
                                 # are only reliably addressable by index)
$sync.SimBw         = [hashtable]::Synchronized(@{})   # test hook: r / t Mbps

$script:Subnet   = '192.168.137'
$script:ServerIP = "$($script:Subnet).1"

# =====================================================================
# helpers
# =====================================================================
function Log([string]$t) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $sync.Log.Add("$stamp  $t") | Out-Null
    if ($sync.Log.Count -gt 300) { $sync.Log.RemoveRange(0, 100) }
}

function Load-Settings {
    if (Test-Path $SettingsFile) {
        try { return (Get-Content $SettingsFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-Settings {
    param($ssid, $pass, $uplink, $routerMode, $vrmode, $autostart, $serverIp)
    try {
        $o = [pscustomobject]@{ ssid = $ssid; pass = $pass; uplink = $uplink; routerMode = $routerMode; vrmode = $vrmode; autostart = $autostart; serverIp = $serverIp }
        $o | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch { Log "Could not save settings: $($_.Exception.Message)" }
}

function Norm-Mac([string]$m) {
    return (($m -replace '[:-]', '') -replace '\s', '').ToLower()
}

function Format-MacDisp([string]$m) {
    # pretty display form: aa:bb:cc:dd:ee:ff (accepts any format)
    $b = Norm-Mac $m
    if ($b -match '^[0-9a-f]{12}$') {
        return ($b -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6')
    }
    return $m
}

function Load-Reservations {
    if (-not (Test-Path $ResvFile)) { return @() }
    try {
        $out = @(Import-Csv $ResvFile | ForEach-Object {
            [pscustomobject]@{ mac = (Norm-Mac ([string]$_.mac)); ip = ([string]$_.ip); name = ([string]$_.name) }
        })
        # a hand-edited CSV may contain junk - drop rows that would break
        # the DHCP server (empty/malformed MAC or unparseable IP)
        $valid = @()
        foreach ($r in $out) {
            $ipOk = $false
            try { $null = [System.Net.IPAddress]::Parse($r.ip); $ipOk = $true } catch { }
            if ($r.mac -match '^[0-9a-f]{12}$' -and $ipOk) { $valid += $r }
            else { Log "Ignored invalid reservation row: '$($r.name)' $($r.mac) $($r.ip)" }
        }
        return $valid
    } catch { return @() }
}

function Save-Reservations([array]$list) {
    try {
        if ($list.Count -eq 0) { Remove-Item $ResvFile -ErrorAction SilentlyContinue; return }
        $list | Select-Object mac, ip, name | Export-Csv -Path $ResvFile -NoTypeInformation -Encoding UTF8
    } catch { Log "Could not save reservations: $($_.Exception.Message)" }
}

function Get-Reservations {
    if ($null -eq $script:ResvCache) { $script:ResvCache = @(Load-Reservations) }
    return $script:ResvCache
}

# single entry point for every reservation change: writes the CSV,
# refreshes the GUI cache and updates the live DHCP reservation table
# (so reservations apply immediately, no hotspot restart needed).
function Set-Reservations([array]$list) {
    $list = @($list | ForEach-Object {
        [pscustomobject]@{ mac = (Norm-Mac ([string]$_.mac)); ip = ([string]$_.ip); name = ([string]$_.name) }
    })
    Save-Reservations $list
    $script:ResvCache = $list
    $h = @{}
    foreach ($r in $list) { $h[$r.mac] = $r.ip }
    $sync.Reservations = $h
}

# device display name: reservation name first, then the hostname the
# device itself reported via DHCP (option 12), else $null.
function Resolve-DeviceName([string]$mac) {
    $k = Norm-Mac $mac
    if (-not $k) { return $null }
    foreach ($r in (Get-Reservations)) {
        if (((Norm-Mac $r.mac) -eq $k) -and $r.name) { return $r.name }
    }
    $disp = Format-MacDisp $k
    if ($sync.Hostnames.ContainsKey($disp)) {
        $hn = [string]$sync.Hostnames[$disp]
        if ($hn) { return $hn }
    }
    return $null
}

# next free static IP suggestion: .50 upward, skipping addresses that
# are already reserved or currently in use by a connected device
function Get-SuggestedIP {
    $sub = Get-ActiveSubnet
    # never suggest the hotspot PC's own address - which is not
    # necessarily .1 anymore now that the gateway IP is configurable
    $gws = @("$sub.1")
    if ($script:ServerIP -and ($script:ServerIP -like "$sub.*")) { $gws += $script:ServerIP }
    if ($script:Running -and [string]$sync.ServerIP) { $gws += [string]$sync.ServerIP }
    $taken = @($gws)
    foreach ($r in (Get-Reservations)) { $taken += $r.ip }
    foreach ($c in @($sync.Clients)) { $taken += $c.ip }
    for ($n = 50; $n -lt 100; $n++) {
        $cand = "$sub.$n"
        if ($taken -notcontains $cand) { return $cand }
    }
    return "$sub.50"
}

# Validate a candidate hotspot (gateway) IP. Returns the implied /24
# subnet ("192.168.50" for 192.168.50.1) on success, $null on failure
# and leaves a human-readable reason in $script:IpErr. Any private
# range is accepted - the app is no longer locked to 192.168.137.x.
function Test-ServerIP([string]$s) {
    # strict dotted-quad form first: .NET's legacy parser happily accepts
    # "10.1" (-> 10.0.0.1) and leading zeros, which would silently mean
    # a different network than the user typed
    $script:IpErr = ''
    $script:IpCanonical = ''
    $s = "$s".Trim()
    if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $script:IpErr = 'Not a valid IPv4 address (example: 192.168.50.1)'; return $null }
    $ipObj = $null
    if (-not [System.Net.IPAddress]::TryParse($s, [ref]$ipObj)) { $script:IpErr = 'Not a valid IPv4 address'; return $null }
    if ($ipObj.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { $script:IpErr = 'IPv4 only (no IPv6)'; return $null }
    $b = $ipObj.GetAddressBytes()
    $priv = ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
    if (-not $priv) { $script:IpErr = 'Use a private range (10 / 172.16-31 / 192.168)'; return $null }
    if ($b[3] -eq 0 -or $b[3] -eq 255) { $script:IpErr = 'Last number cannot be 0 or 255'; return $null }
    $script:IpCanonical = ('{0}.{1}.{2}.{3}' -f [int]$b[0], [int]$b[1], [int]$b[2], [int]$b[3])
    return ('{0}.{1}.{2}' -f [int]$b[0], [int]$b[1], [int]$b[2])
}

# True when the two IPv4 prefixes overlap (either contains the other).
# The hotspot is always a /24, but the uplink can be anything - a /16
# uplink on 192.168.0.0 must block a 192.168.50.0/24 hotspot even though
# no /24 string comparison would notice.
function Test-SubnetOverlap([string]$netA, [int]$lenA, [string]$netB, [int]$lenB) {
    try {
        $a = [System.Net.IPAddress]::Parse($netA).GetAddressBytes()
        $b = [System.Net.IPAddress]::Parse($netB).GetAddressBytes()
    } catch { return $false }
    if ($a.Count -ne 4 -or $b.Count -ne 4) { return $false }
    if ($lenA -lt 0 -or $lenA -gt 32) { $lenA = 32 }
    if ($lenB -lt 0 -or $lenB -gt 32) { $lenB = 32 }
    $bits = [Math]::Min($lenA, $lenB)
    $fullBytes = [int][Math]::Floor($bits / 8)
    $rem = $bits % 8
    for ($i = 0; $i -lt 4; $i++) {
        if ($i -lt $fullBytes) {
            if ($a[$i] -ne $b[$i]) { return $false }
        }
        elseif ($i -eq $fullBytes -and $rem -gt 0) {
            $m = 256 - [int][Math]::Pow(2, (8 - $rem))
            if (($a[$i] -band $m) -ne ($b[$i] -band $m)) { return $false }
        }
    }
    return $true
}

# The subnet the RUNNING hotspot actually uses (Shared mode adopts the
# ICS-assigned one at start); before/after a run this is the configured
# one. Everything user-facing (suggestions, dialog validation) must use
# THIS value, never the raw configured one, or the two diverge the
# moment the Hotspot IP box is edited while running.
function Get-ActiveSubnet {
    if ($script:Running) {
        $s = [string]$sync.Subnet
        if ($s) { return $s }
    }
    return $script:Subnet
}

# Byte count -> compact human string ("812 MB", "2.18 GB")
function Format-Bytes([double]$v) {
    if ($v -lt 0) { return '?' }
    if ($v -lt 1024) { return ('{0} B' -f [int]$v) }
    if ($v -lt 1048576) { return ('{0:N1} KB' -f ($v / 1024)) }
    if ($v -lt 1073741824) { return ('{0:N1} MB' -f ($v / 1048576)) }
    return ('{0:N2} GB' -f ($v / 1073741824))
}

function Get-UplinkAdapters {
    if (-not $script:HasNetAdapter) { return $null }
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi Direct|Hosted|Tailscale|Loopback' } |
        Sort-Object -Property @{Expression = { if ($_.InterfaceDescription -like '*802.11*') { 0 } else { 1 } }}
}

function Get-WfdAdapter {
    if (-not $script:HasNetAdapter) { return $null }
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Wi-Fi Direct' -and $_.Status -ne 'Disconnected' } |
        Select-Object -First 1
}

function Get-PhysicalWifi {
    if (-not $script:HasNetAdapter) { return $null }
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -like '*802.11*' } | Select-Object -First 1
}

function Disable-AdapterPowerSaving([string]$name) {
    try {
        Disable-NetAdapterPowerManagement -Name $name -NoRestart -ErrorAction Stop | Out-Null
        Log "Power saving disabled on '$name' (always off in this app, by design)"
    } catch { Log "Could not disable power saving on '$name': $($_.Exception.Message)" }
}

# Keeps the UI alive while the main thread waits. In the GUI this
# pumps the message loop (so the window does not freeze and the log
# keeps painting during start/stop); in self-test mode it just sleeps.
function Invoke-UIPump([int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        if (-not $SelfTest -and ('System.Windows.Forms.Application' -as [type])) {
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            Start-Sleep -Milliseconds 20
        }
        else {
            Start-Sleep -Milliseconds 50
        }
    }
}

# =====================================================================
# VR mode (pause WLAN AutoConfig background scans = dropout fix)
# =====================================================================
function Enable-VRMode {
    $w = Get-PhysicalWifi
    if (-not $w) { Log 'VR mode: no physical Wi-Fi adapter found - scans not paused.'; return }
    # write the crash-recovery flag BEFORE pausing, so a crash between
    # these two steps can never leave scans paused with no flag.
    # UTF8 (not ASCII): adapter names can contain non-ASCII characters,
    # and an ASCII-mangled name would strand AutoConfig disabled forever.
    $flagWritten = $false
    try { Set-Content -Path $VrFlagFile -Value $w.Name -Encoding UTF8 -ErrorAction Stop; $flagWritten = $true }
    catch {
        # read-only install folder (e.g. extracted under Program Files) - fall back to %TEMP%
        try { Set-Content -Path $VrFlagAlt -Value $w.Name -Encoding UTF8 -ErrorAction Stop; $flagWritten = $true } catch { }
    }
    netsh wlan set autoconfig enabled=no interface="$($w.Name)" 2>&1 | Out-Null
    if (-not $flagWritten) { Log 'VR mode: could not write the crash-recovery flag (scans are still paused).' }
    Log "VR mode ON : background Wi-Fi scans paused on '$($w.Name)' (dropout fix)"
    Log '  Windows will not react to network changes until the hotspot stops.'
}

# Resumes scans if either flag file exists (script dir or %TEMP%
# fallback). Returns $true when a paused state was actually found and
# cleared - used both by normal stop and by crash recovery.
function Disable-VRMode {
    $had = $false
    foreach ($f in @($VrFlagFile, $VrFlagAlt)) {
        if ($f -and (Test-Path $f)) {
            $wname = [string](Get-Content $f -ErrorAction SilentlyContinue | Select-Object -First 1)
            if (-not $wname) { $w = Get-PhysicalWifi; if ($w) { $wname = $w.Name } }
            if ($wname) {
                netsh wlan set autoconfig enabled=yes interface="$wname" 2>&1 | Out-Null
                Log "VR mode OFF: background Wi-Fi scans resumed on '$wname'"
            }
            Remove-Item $f -ErrorAction SilentlyContinue
            $had = $true
        }
    }
    return $had
}

# ---------- ICS sharing (Shared mode) ----------
function Disable-AllIcs {
    try {
        $shr = New-Object -ComObject HNetCfg.HNetShare
        foreach ($c in $shr.EnumEveryConnection) {
            $cfg = $shr.INetSharingConfigurationForINetConnection($c)
            try { $cfg.DisableSharing() } catch { }
        }
    } catch { Log "ICS COM not available: $($_.Exception.Message)" }
}

function Enable-IcsOnNames([string]$uplinkName, [string]$privateName) {
    $shr = New-Object -ComObject HNetCfg.HNetShare
    $okPub = $false; $okPriv = $false
    foreach ($c in $shr.EnumEveryConnection) {
        $props = $shr.NetConnectionProps($c)
        $cfg = $shr.INetSharingConfigurationForINetConnection($c)
        if ($props.Name -eq $uplinkName)  { try { $cfg.EnableSharing(0); $okPub = $true } catch { } }
        if ($props.Name -eq $privateName) { try { $cfg.EnableSharing(1); $okPriv = $true } catch { } }
    }
    return ($okPub -and $okPriv)
}
# =====================================================================
# built-in DHCP server source (runs in a background runspace)
#
# MAC normalization: reservation keys and packet MACs are both
# normalized through MacKey (bare, lowercase) before comparison -
# this is the fix for static IP reservations never matching (v1/v2
# bug: CSV keys had no colons, packet MACs did).
#
# Test hooks (defaults are the production values):
#   $sync.DhcpPort / $sync.ClientPort  - UDP ports (67 / 68)
#   $sync.Broadcast                    - reply destination (255.255.255.255)
# =====================================================================
$DhcpSource = @'
param($sync)
$ErrorActionPreference = 'Continue'
function Log($t) { $sync.Log.Add("$(Get-Date -Format 'HH:mm:ss')  [dhcp] $t") | Out-Null }
function MacStr([byte[]]$b) { ($b[0..5] | ForEach-Object { $_.ToString('x2') }) -join ':' }
function MacKey([string]$m) { (($m -replace '[:-]', '') -replace '\s', '').ToLower() }
function IPBytes([string]$s) { ([System.Net.IPAddress]::Parse($s)).GetAddressBytes() }

function Read-Options([byte[]]$p) {
    $opts = @{}
    $i = 240
    while ($i -lt $p.Length - 2) {
        $code = $p[$i]
        if ($code -eq 0) { $i++; continue }
        if ($code -eq 255) { break }
        $len = $p[$i+1]
        $val = @()
        if ($len -gt 0 -and $i + 2 + $len -le $p.Length) { $val = @($p[($i+2)..($i+1+$len)]) }
        $opts[[int]$code] = $val
        $i += 2 + $len
    }
    return $opts
}

function OptStrIP($opts, [int]$code) {
    if ($opts.ContainsKey($code) -and $opts[$code].Count -ge 4) {
        return ('{0}.{1}.{2}.{3}' -f [int]$opts[$code][0], [int]$opts[$code][1], [int]$opts[$code][2], [int]$opts[$code][3])
    }
    return $null
}

function New-Reply([byte[]]$req, [string]$yiaddr, [int]$msgType, [string]$srvIp) {
    $r = New-Object byte[] 300
    $r[0] = 2; $r[1] = $req[1]; $r[2] = $req[2]; $r[3] = $req[3]
    [Array]::Copy($req, 4,  $r, 4,  4)    # xid
    [Array]::Copy($req, 10, $r, 10, 2)    # flags
    [Array]::Copy($req, 28, $r, 28, 16)   # chaddr
    $y = IPBytes $yiaddr
    [Array]::Copy($y, 0, $r, 16, 4)       # yiaddr
    $m = IPBytes $srvIp
    [Array]::Copy($m, 0, $r, 20, 4)       # siaddr
    $r[236] = 99; $r[237] = 130; $r[238] = 83; $r[239] = 99  # magic cookie
    $o = New-Object System.Collections.Generic.List[byte]
    $o.Add(53); $o.Add(1); $o.Add($msgType)
    $o.Add(54); $o.Add(4); foreach ($b in $m) { $o.Add($b) }
    # option 51: lease time 12h, 58/59: renewal (T1) / rebind (T2).
    # DHCP integer options are NETWORK byte order (big-endian) - the
    # raw BitConverter bytes would hand clients a ~102-year lease.
    $o.Add(51); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder([int]43200))) { $o.Add($b) }
    $o.Add(58); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder([int]21600))) { $o.Add($b) }
    $o.Add(59); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder([int]37800))) { $o.Add($b) }
    $o.Add(1);  $o.Add(4); foreach ($b in (IPBytes '255.255.255.0')) { $o.Add($b) }
    $o.Add(3);  $o.Add(4); foreach ($b in $m) { $o.Add($b) }
    $dns = @(IPBytes '1.1.1.1') + @(IPBytes '8.8.8.8')
    $o.Add(6);  $o.Add($dns.Count); foreach ($b in $dns) { $o.Add($b) }
    $o.Add(255)
    $arr = $o.ToArray()
    [Array]::Copy($arr, 0, $r, 240, $arr.Length)
    return $r
}

$ip        = [string]$sync.ServerIP
$subnet    = [string]$sync.Subnet
$poolStart = 100; if ($sync.PoolStart) { $poolStart = [int]$sync.PoolStart }
$poolEnd   = 200; if ($sync.PoolEnd)   { $poolEnd   = [int]$sync.PoolEnd }
$port      = 67;   if ($sync.DhcpPort)  { $port  = [int]$sync.DhcpPort }
$cport     = 68;   if ($sync.ClientPort){ $cport = [int]$sync.ClientPort }
$bcast     = '255.255.255.255'; if ($sync.Broadcast) { $bcast = [string]$sync.Broadcast }

$leases = @{}     # mac (colon form) -> ip
$offers = @{}     # mac (colon form) -> ip handed out in an OFFER, not yet ACKed
$offerTime = @{}  # mac -> when the OFFER went out (offers expire after 60 s)
$leaseTime = @{}  # mac -> when the lease was granted/renewed (12 h lease)

# publish an immutable lease snapshot for the client tracker (never
# enumerate the synchronized $sync.Leases from another thread)
function Publish-Leases {
    $snap = @()
    foreach ($k in @($leases.Keys)) {
        $snap += [pscustomobject]@{ mac = $k; ip = [string]$leases[$k] }
    }
    $sync.LeaseList = $snap
}

function Get-FreeIP([string]$macKey, [string]$macDisp) {
    # reservations are read LIVE from $sync.Reservations so the GUI can
    # add/remove them while the hotspot runs. Two guards:
    #  - only reservations INSIDE this server's subnet are honored (the
    #    GUI keeps rows for other subnets around after a subnet change;
    #    handing one out would silently break the client)
    #  - if another device currently holds the reserved address, fall
    #    through to the pool instead of ACKing a duplicate
    if ($sync.Reservations) {
        foreach ($k in @($sync.Reservations.Keys)) {
            if ((MacKey ([string]$k)) -eq $macKey) {
                $rip = [string]$sync.Reservations[$k]
                if ($rip -like "$subnet.*") {
                    $heldBy = $null
                    foreach ($lk in @($leases.Keys)) {
                        if ($lk -ne $macDisp -and [string]$leases[$lk] -eq $rip) { $heldBy = $lk; break }
                    }
                    if (-not $heldBy) { return $rip }
                    Log "reservation $rip is currently held by $heldBy - using the pool for $macDisp"
                }
                break
            }
        }
    }
    if ($leases.ContainsKey($macDisp)) { return $leases[$macDisp] }
    if ($offers.ContainsKey($macDisp)) { return $offers[$macDisp] }
    $used = @($leases.Values) + @($offers.Values)
    if ($sync.Reservations) { foreach ($v in @($sync.Reservations.Values)) { $used += [string]$v } }
    for ($n = $poolStart; $n -le $poolEnd; $n++) {
        $cand = "$subnet.$n"
        if ($used -notcontains $cand) { return $cand }
    }
    return $null
}

try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.ExclusiveAddressUse = $false
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::Broadcast, $true)
    $udp.Client.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($ip), $port)))
    $udp.Client.ReceiveTimeout = 700
    Log "DHCP server listening on ${ip}:$port"
} catch {
    Log "DHCP bind FAILED: $($_.Exception.Message)"
    try { $udp.Close() } catch { }
    return
}

$dst = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($bcast), $cport)
try {
    while (-not $sync.Stop) {
        # expire stale offers so a DISCOVER that was never followed by a
        # REQUEST cannot permanently eat a pool address; expire leases
        # past their 12 h lifetime so the pool cannot run dry in a very
        # long session (renewals refresh the timestamp)
        $changed = $false
        foreach ($k in @($offerTime.Keys)) {
            if (((Get-Date) - $offerTime[$k]).TotalSeconds -gt 60) { $offers.Remove($k); $offerTime.Remove($k); $changed = $true }
        }
        foreach ($k in @($leaseTime.Keys)) {
            if (((Get-Date) - $leaseTime[$k]).TotalSeconds -gt 43260) {
                $leases.Remove($k); $sync.Leases.Remove($k); $leaseTime.Remove($k)
                Log "lease expired: $k"
                $changed = $true
            }
        }
        if ($changed) { Publish-Leases }
        $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
        $req = $null
        try { $req = $udp.Receive([ref]$ep) }
        catch {
            # a Receive timeout is the normal heartbeat; any other socket
            # error must not spin the loop at 100% CPU
            Start-Sleep -Milliseconds 50
            continue
        }
        if ($null -eq $req -or $req.Length -lt 240) { continue }
        if ($req[236] -ne 99 -or $req[237] -ne 130 -or $req[238] -ne 83 -or $req[239] -ne 99) { continue }
        $macDisp = MacStr $req[28..43]
        $macKey  = MacKey $macDisp
        $opts = Read-Options $req
        $msgType = 0
        if ($opts.ContainsKey(53) -and $opts[53].Count -ge 1) { $msgType = [int]$opts[53][0] }

        if ($msgType -eq 1) {
            $offer = Get-FreeIP $macKey $macDisp
            if ($offer) {
                $offers[$macDisp] = $offer
                $offerTime[$macDisp] = Get-Date
                try { $udp.Send((New-Reply $req $offer 2 $ip), 300, $dst) | Out-Null; Log "OFFER $offer to $macDisp" }
                catch { Log "OFFER send failed: $($_.Exception.Message)" }
            } else { Log "POOL FULL - no address for $macDisp" }
        }
        elseif ($msgType -eq 3) {
            # REQUEST -> ACK / NAK (silence if it is selecting another server)
            $srvSel = OptStrIP $opts 54
            if ($srvSel -and $srvSel -ne $ip) { continue }
            $wanted = OptStrIP $opts 50
            if (-not $wanted -and ($req[12] -or $req[13] -or $req[14] -or $req[15])) {
                $wanted = ('{0}.{1}.{2}.{3}' -f [int]$req[12], [int]$req[13], [int]$req[14], [int]$req[15])
            }
            $assigned = Get-FreeIP $macKey $macDisp
            if ($assigned -and $wanted -eq $assigned) {
                $leases[$macDisp] = $assigned
                $sync.Leases[$macDisp] = $assigned
                $leaseTime[$macDisp] = Get-Date
                $offers.Remove($macDisp)
                $offerTime.Remove($macDisp)
                try { $udp.Send((New-Reply $req $assigned 5 $ip), 300, $dst) | Out-Null } catch { }
                $name = ''
                if ($opts.ContainsKey(12) -and $opts[12].Count -gt 0) {
                    # the hostname is guest-controlled: strip anything that
                    # could forge log lines and cap its length
                    $name = [System.Text.Encoding]::ASCII.GetString($opts[12])
                    $name = ($name -replace '[^\x20-\x7E]', '').Trim()
                    if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
                }
                if ($name) { try { $sync.Hostnames[$macDisp] = $name } catch { } }
                Log "ACK $assigned to $macDisp $name"
                Publish-Leases
            } else {
                try { $udp.Send((New-Reply $req '0.0.0.0' 6 $ip), 300, $dst) | Out-Null } catch { }
                Log "NAK $macDisp (wanted $wanted, assigned $assigned)"
            }
        }
        elseif ($msgType -eq 4) {
            # DECLINE - the client found the address in use; drop it everywhere
            $leases.Remove($macDisp)
            $sync.Leases.Remove($macDisp)
            $offers.Remove($macDisp)
            $offerTime.Remove($macDisp)
            Publish-Leases
            Log "DECLINE $macDisp (address conflict reported - address returned to pool)"
        }
        elseif ($msgType -eq 7) {
            # RELEASE
            if ($leases.ContainsKey($macDisp)) {
                $sync.Leases.Remove($macDisp)
                $leases.Remove($macDisp)
                $leaseTime.Remove($macDisp)
                Publish-Leases
                Log "RELEASE $macDisp"
            }
        }
    }
} finally {
    try { $udp.Close() } catch { }
}
Log "DHCP server stopped"
'@

# =====================================================================
# client tracker source (runs in a background runspace)
#
# Why this exists (v2.1.0 problems it replaces):
#   - the old GUI rebuilt the device list straight from the ARP
#     neighbor cache every second: entries flap between states while
#     a device associates (the obnoxious blinking), the cache behaves
#     differently with AutoConfig paused (VR mode on), and the whole
#     ListView was cleared + re-added every tick (flicker).
#   - the latency monitor pinged with a 400 ms timeout, which a
#     power-saving client routinely misses, and it only ever pinged
#     "row 1" of that unstable list - and in Router mode the graph
#     was never drawn at all.
#
# How it works now: one table, several kinds of evidence.
#   - neighbor (ARP) rows on the hotspot adapter = the device is
#     associated; rows in Reachable/Probe/Delay state also refresh
#     liveness
#   - DHCP leases (router mode) seed known clients; leased or
#     reserved devices never silently vanish - they degrade to
#     'offline' instead
#   - every client is pinged about once per second (in parallel);
#     success refreshes liveness AND doubles as the keepalive that
#     keeps ARP entries hot - which is also why the list keeps
#     updating while VR mode is on
#   - a device that goes quiet shows 'reconnect' after a grace
#     period, and is only dropped after a longer one
#   - each cycle publishes an immutable snapshot to $sync.Clients
#     that the GUI renders by diff - no flicker, no lost selection
#
# The same pings feed the latency graph ($sync.PingHist). The graph
# target follows the first connected client unless the user pins one
# ($sync.TargetLocked - set by "Watch latency" in the GUI).
#
# Test hooks ($sync.Sim = $true): neighbors come from
#   $sync.SimNeighbors (ArrayList of @{ ip; mac; state }) and ping
#   results from $sync.SimPing (ip -> int ms; -1 = no reply;
#   -2 = do a REAL ping, used for loopback testing). Grace periods
#   are overridable via $sync.GraceOnline / $sync.GraceRemove
#   (seconds; read once at start; 0 = defaults 12 / 45).
# =====================================================================
$ClientScanSource = @'
param($sync)
$ErrorActionPreference = 'Continue'
function Log($t) { $sync.Log.Add("$(Get-Date -Format 'HH:mm:ss')  [clients] $t") | Out-Null }
function MacKey([string]$m) { (($m -replace '[:-]', '') -replace '\s', '').ToLower() }
function MacColon([string]$m) {
    $b = MacKey $m
    if ($b -match '^[0-9a-f]{12}$') {
        return ($b -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6')
    }
    return $m
}

$sim      = [bool]$sync.Sim
$subnet   = [string]$sync.Subnet
$ifIndex  = [int]$sync.ScanIfIndex
$router   = [bool]$sync.RouterMode
$graceOn  = 12; if ($sync.GraceOnline) { $graceOn = [int]$sync.GraceOnline }
$graceRm  = 45; if ($sync.GraceRemove) { $graceRm = [int]$sync.GraceRemove }
$hasNb    = [bool](Get-Command -Name Get-NetNeighbor -ErrorAction SilentlyContinue)
$fresh    = @('Reachable', 'Probe', 'Delay', 'Permanent')
# bandwidth sampling state (hotspot adapter counters)
$hasStat  = [bool](Get-Command -Name Get-NetAdapterStatistics -ErrorAction SilentlyContinue)
$bwIf     = [string]$sync.BwIfName
$bwIdx    = [int]$sync.BwIfIndex
$prevNow  = Get-Date
$prevR    = -1L; $prevT = -1L
$baseR    = 0L;  $baseT = 0L
$firstStat = $true
$statFails = 0
if (-not $hasStat) { $sync.BwFail = $true }

if ($sim) { Log 'client tracking started (sim mode)' }
else      { Log "client tracking started on interface $ifIndex" }

$table = @{}
while (-not $sync.StopScan) {
    $now = Get-Date

    # ---- 1. neighbor evidence (real adapter or simulated) --------
    # (ToArray on the synchronized lists takes the internal lock, so the
    #  copy cannot hit a mid-enumeration modification from the harness)
    $rows = @()
    if ($sim) {
        $rows = @($sync.SimNeighbors.ToArray())
    }
    elseif ($hasNb -and $ifIndex -gt 0) {
        try {
            $rows = @(Get-NetNeighbor -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like "$subnet.*" -and $_.LinkLayerAddress } |
                ForEach-Object { @{ ip = [string]$_.IPAddress; mac = [string]$_.LinkLayerAddress; state = [string]$_.State } })
        } catch { $rows = @() }
    }

    # ---- 2. seed DHCP lease clients (router mode) -----------------
    # (the DHCP server publishes an immutable snapshot; never enumerate
    #  the synchronized lease hashtable from this thread)
    if ($router) {
        foreach ($le in @($sync.LeaseList)) {
            $k = MacKey ([string]$le.mac)
            $ip = [string]$le.ip
            if (-not $k -or $k -notmatch '^[0-9a-f]{12}$' -or -not $ip) { continue }
            if ($table.ContainsKey($k)) {
                # seen via ARP first - it now also has a lease: mark it
                # sticky and adopt the leased address
                $table[$k].lease = $true
                $table[$k].ip = $ip
            }
            else {
                $table[$k] = @{ macKey = $k; macDisp = (MacColon $k); ip = $ip; firstSeen = $now; lastSeen = $now; lastAlive = $now; lastMs = -1; lease = $true }
                Log "client appeared (DHCP lease): $ip $(MacColon $k)"
            }
        }
    }

    # ---- 3. merge neighbor rows ------------------------------------
    foreach ($r in $rows) {
        $k = MacKey ([string]$r.mac)
        if (-not $k -or $k -notmatch '^[0-9a-f]{12}$') { continue }
        if ($k -match '^(ff|01005e|3333)') { continue }        # multicast/broadcast MACs
        $ip = [string]$r.ip
        # our own address: the classic .1 OR the configured gateway
        if (-not $ip -or $ip -eq "$subnet.1" -or $ip -eq ([string]$sync.ServerIP)) { continue }
        $state = [string]$r.state
        if ($table.ContainsKey($k)) {
            $e = $table[$k]
            $e.ip = $ip
            $e.lastSeen = $now
            if ($sim -or ($fresh -contains $state)) { $e.lastAlive = $now }
        }
        else {
            $table[$k] = @{ macKey = $k; macDisp = (MacColon $k); ip = $ip; firstSeen = $now; lastSeen = $now; lastAlive = $now; lastMs = -1; lease = $false }
            Log "client connected: $ip $(MacColon $k)"
        }
    }

    # ---- 4. ping every client (parallel; also the keepalive) ------
    $entries = @($table.Values | Sort-Object -Property firstSeen)
    if ($entries.Count -gt 32) { $entries = @($entries[0..31]) }
    $tasks = @()
    foreach ($e in $entries) {
        if ($sim) {
            $v = $null
            if ($sync.SimPing.ContainsKey($e.ip)) { $v = [int]$sync.SimPing[$e.ip] }
            if ($null -ne $v -and $v -ge 0) {
                $e.lastMs = $v; $e.lastSeen = $now; $e.lastAlive = $now
            }
            elseif ($null -ne $v -and $v -eq -2) {
                # -2 = do a REAL ping even in sim mode (loopback testing)
                $sp = $null
                try {
                    $sp = New-Object System.Net.NetworkInformation.Ping
                    $rr = $sp.Send($e.ip, 800)
                    if ($rr.Status.ToString() -eq 'Success') { $e.lastMs = [int]$rr.RoundtripTime; $e.lastSeen = $now; $e.lastAlive = $now }
                    else { $e.lastMs = -1 }
                } catch { $e.lastMs = -1 }
                finally { if ($sp) { try { $sp.Dispose() } catch { } } }
            }
            else { $e.lastMs = -1 }
        }
        else {
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $tasks += @{ ping = $p; task = $p.SendPingAsync($e.ip); entry = $e }
            } catch { $e.lastMs = -1 }
        }
    }
    if (@($tasks).Count -gt 0) {
        $tarr = @($tasks | ForEach-Object { $_.task })
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tarr, 1200) } catch { }
        foreach ($t in $tasks) {
            $e = $t.entry
            $ok = $false
            try {
                if ($t.task.IsCompleted -and -not $t.task.IsFaulted) {
                    $res = $t.task.Result
                    if ($res.Status.ToString() -eq 'Success') { $ok = $true; $e.lastMs = [int]$res.RoundtripTime }
                }
            } catch { }
            if ($ok) { $e.lastSeen = $now; $e.lastAlive = $now }
            else { $e.lastMs = -1 }
            try { $t.ping.Dispose() } catch { }
        }
    }

    # ---- 4b. bandwidth sample (hotspot adapter counters) -----------
    # Rates are Mbps over the real elapsed time; -1 marks "no sample".
    # A counter wrap/reset (adapter recreated) just re-baselines the
    # session totals and skips one rate sample.
    $bwR = -1.0; $bwT = -1.0
    if ($sim) {
        if ($sync.SimBw.ContainsKey('r')) { $bwR = [double]$sync.SimBw['r'] }
        if ($sync.SimBw.ContainsKey('t')) { $bwT = [double]$sync.SimBw['t'] }
        if ($bwR -ge 0 -or $bwT -ge 0) { $sync.BwOk = $true }
    }
    elseif ($hasStat -and ($bwIdx -gt 0 -or $bwIf)) {
        try {
            # sample by interface INDEX with -IncludeHidden: the WFD
            # virtual adapter is hidden, and its name contains a literal
            # '*' which -Name would treat as a wildcard (multi-match ->
            # array -> cast failure every cycle)
            $stats = @()
            if ($bwIdx -gt 0) {
                $stats = @(Get-NetAdapterStatistics -InterfaceIndex $bwIdx -IncludeHidden -ErrorAction Stop)
            }
            else {
                $stats = @(Get-NetAdapterStatistics -Name $bwIf -IncludeHidden -ErrorAction Stop |
                           Where-Object { $_.Name -eq $bwIf })
            }
            if ($stats.Count -ne 1) { throw 'adapter statistics not found' }
            $st = $stats[0]
            $r = [long]$st.ReceivedBytes
            $t = [long]$st.SentBytes
            $dt = ($now - $prevNow).TotalSeconds
            if ($dt -gt 0.2) {
                if ($r -lt $prevR) { $baseR = $r }   # counter reset
                if ($t -lt $prevT) { $baseT = $t }
                if (-not $firstStat -and $r -ge $prevR -and $t -ge $prevT) {
                    $bwR = (($r - $prevR) * 8.0) / ($dt * 1000000.0)
                    $bwT = (($t - $prevT) * 8.0) / ($dt * 1000000.0)
                }
                if ($firstStat) { $baseR = $r; $baseT = $t; $firstStat = $false }
                if ($bwR -ge 0 -or $bwT -ge 0) { $sync.BwOk = $true }
                $sync.BwTotalR = [long][Math]::Max(0, ($r - $baseR))
                $sync.BwTotalT = [long][Math]::Max(0, ($t - $baseT))
                $statFails = 0
                $sync.BwFail = $false
            }
            $prevR = $r; $prevT = $t
            $prevNow = $now
        } catch {
            $statFails++
            if ($statFails -ge 10) { $sync.BwFail = $true }
        }
    }
    [void]$sync.BwHistR.Add($bwR)
    [void]$sync.BwHistT.Add($bwT)
    try { if ($sync.BwHistR.Count -gt 180) { $sync.BwHistR.RemoveRange(0, ($sync.BwHistR.Count - 180)) } } catch { }
    try { if ($sync.BwHistT.Count -gt 180) { $sync.BwHistT.RemoveRange(0, ($sync.BwHistT.Count - 180)) } } catch { }

    # ---- 5. status + expiry ----------------------------------------
    $keep = @{}
    foreach ($k in @($table.Keys)) {
        $e = $table[$k]
        $ageAlive = ($now - $e.lastAlive).TotalSeconds
        $ageSeen  = ($now - $e.lastSeen).TotalSeconds
        $reserved = $false
        if ($sync.Reservations -and $sync.Reservations.ContainsKey($k)) { $reserved = $true }
        if ($ageAlive -le $graceOn) { $e.status = 'connected' }
        else { $e.status = 'reconnect' }
        if ($ageSeen -gt $graceRm) {
            if ($e.lease -or $reserved) { $e.status = 'offline' }
            else { Log "client left: $($e.ip) $($e.macDisp)"; continue }
        }
        # offline rows are kept so leased/reserved devices show where
        # they went - but not forever: after an hour of silence the row
        # is dropped so the 32-slot keepalive budget cannot be starved
        if ($e.status -eq 'offline' -and $ageSeen -gt 3600) {
            Log "client row expired after 1 h offline: $($e.ip) $($e.macDisp)"
            continue
        }
        $keep[$k] = $e
    }
    $table = $keep

    # ---- 6. publish snapshot + run the latency target --------------
    $snap = @()
    foreach ($e in @($table.Values | Sort-Object -Property firstSeen)) {
        $snap += [pscustomobject]@{
            macKey = $e.macKey; macDisp = $e.macDisp; ip = $e.ip
            status = $e.status; ms = $e.lastMs; lease = [bool]$e.lease
        }
    }
    $sync.Clients = $snap

    $tgt = [string]$sync.PingTarget
    # user lock: honored as long as the CURRENT target still exists
    # (fresh reads close the race where a "Watch latency" click lands
    # between the target read and the lock read)
    if ($sync.TargetLocked) {
        $curEntry = $null
        $cur = [string]$sync.PingTarget
        if ($cur) {
            foreach ($e in @($table.Values)) { if ($e.ip -eq $cur) { $curEntry = $e; break } }
        }
        if (-not $curEntry) { $sync.TargetLocked = $false }
    }
    if (-not $sync.TargetLocked) {
        $tgtEntry = $null
        if ($tgt) {
            foreach ($e in @($table.Values)) { if ($e.ip -eq $tgt) { $tgtEntry = $e; break } }
        }
        if (-not $tgtEntry) {
            $pick = $null
            foreach ($e in @($table.Values | Sort-Object -Property firstSeen)) {
                if ($e.status -eq 'connected') { $pick = $e; break }
            }
            if ($pick) {
                if ($pick.ip -ne $tgt) {
                    # switching graph targets: start a clean history so the
                    # window does not mix two different devices
                    $sync.PingHist.Clear()
                    Log "graph target: following $($pick.ip) ($($pick.macDisp))"
                }
                $sync.PingTarget = $pick.ip
                $sync.TargetMac  = $pick.macKey
                $nm = 'client'
                if ($sync.Hostnames -and $sync.Hostnames.ContainsKey($pick.macDisp)) {
                    $hn = [string]$sync.Hostnames[$pick.macDisp]
                    if ($hn) { $nm = $hn }
                }
                $sync.TargetName = $nm
            }
            elseif ($tgt) {
                $sync.PingTarget = $null; $sync.TargetMac = $null; $sync.TargetName = $null
            }
        }
    }
    # graph point for the (possibly just-updated) target
    $gt = [string]$sync.PingTarget
    if ($gt) {
        $ge = $null
        foreach ($e in @($table.Values)) { if ($e.ip -eq $gt) { $ge = $e; break } }
        if ($ge) {
            [void]$sync.PingHist.Add($ge.lastMs)
            # the trim can race a concurrent Clear() from a user's
            # "Watch latency" click - losing one trim is harmless
            try { if ($sync.PingHist.Count -gt 180) { $sync.PingHist.RemoveRange(0, $sync.PingHist.Count - 180) } } catch { }
        }
    }

    # ---- 7. pace the loop to about one cycle per second -------------
    $spent = ((Get-Date) - $now).TotalMilliseconds
    $rest = [int](1000 - $spent)
    if ($rest -gt 40) { Start-Sleep -Milliseconds $rest }
    elseif ($rest -le 0) { Start-Sleep -Milliseconds 40 }
}
Log 'client tracking stopped'
'@

# =====================================================================
# client tracker start/stop (used by the GUI and by the test harness)
# =====================================================================
function Start-ClientScan {
    Stop-ClientScan
    $sync.StopScan     = $false
    $sync.Clients      = @()
    $sync.PingHist.Clear()
    $sync.BwHistR.Clear()
    $sync.BwHistT.Clear()
    $sync.BwOk    = $false
    $sync.BwFail  = $false
    $sync.BwTotalR = [long]0
    $sync.BwTotalT = [long]0
    $sync.PingTarget   = $null
    $sync.TargetMac    = $null
    $sync.TargetName   = $null
    $sync.TargetLocked = $false
    $script:ScanDeadLogged = $false
    $script:ScanRun = [powershell]::Create().AddScript($ClientScanSource).AddArgument($sync)
    $script:ScanHandle = $script:ScanRun.BeginInvoke()
}

function Stop-ClientScan {
    $sync.StopScan = $true
    if ($script:ScanHandle) {
        $deadline = (Get-Date).AddSeconds(3)
        while (-not $script:ScanHandle.IsCompleted -and (Get-Date) -lt $deadline) { Invoke-UIPump 150 }
        if ($script:ScanHandle.IsCompleted) {
            # surface a tracker crash instead of letting it die silently
            try { $null = $script:ScanRun.EndInvoke($script:ScanHandle) }
            catch { Log "client tracker ended with an error: $($_.Exception.Message)" }
        }
        try { $script:ScanRun.Stop() } catch { }
        try { $script:ScanRun.Dispose() } catch { }
        $script:ScanRun = $null; $script:ScanHandle = $null
    }
    $sync.PingTarget = $null
    $sync.TargetName = $null
    $sync.TargetLocked = $false
    # clear the published snapshot so the GUI does not keep showing
    # frozen 'connected' rows after the hotspot stops
    $sync.Clients = @()
    $sync.BwHistR.Clear()
    $sync.BwHistT.Clear()
}

# =====================================================================
# firewall rule for the built-in DHCP server (router mode).
# Windows Firewall's default inbound policy would silently swallow the
# clients' DHCPDISCOVER broadcasts before they reach our UDP socket.
# Scoped to inbound UDP 67, added on start, removed on stop.
# =====================================================================
$DhcpFwRuleName = 'VR Hotspot Studio DHCP'

function Enable-DhcpFirewallRule {
    try {
        netsh advfirewall firewall delete rule name="$DhcpFwRuleName" 2>&1 | Out-Null
        $out = netsh advfirewall firewall add rule name="$DhcpFwRuleName" dir=in action=allow protocol=UDP localport=67 2>&1
        if ("$out" -match 'Ok|determinato|OK') { Log 'Firewall: inbound UDP 67 allowed for the built-in DHCP server' }
        else { Log "Firewall rule could not be added - if devices fail to get an IP, allow UDP 67 manually. ($out)" }
    } catch { Log "Firewall rule could not be added: $($_.Exception.Message)" }
}

function Disable-DhcpFirewallRule {
    try { netsh advfirewall firewall delete rule name="$DhcpFwRuleName" 2>&1 | Out-Null } catch { }
}

# =====================================================================
# start / stop logic
# =====================================================================
function Stop-DhcpServer {
    $sync.Stop = $true
    if ($script:DhcpHandle) {
        # give the runspace a moment to leave the blocking Receive call,
        # so a restart can rebind port 67 immediately (v2.0.0 race)
        $deadline = (Get-Date).AddSeconds(3)
        while (-not $script:DhcpHandle.IsCompleted -and (Get-Date) -lt $deadline) { Invoke-UIPump 150 }
        if ($script:DhcpHandle.IsCompleted) {
            try { $null = $script:DhcpRun.EndInvoke($script:DhcpHandle) }
            catch { Log "DHCP server ended with an error: $($_.Exception.Message)" }
        }
        try { $script:DhcpRun.Stop() } catch { }
        try { $script:DhcpRun.Dispose() } catch { }
        $script:DhcpRun = $null; $script:DhcpHandle = $null
    }
}

function Start-Hotspot {
    param([string]$ssid, [string]$pass, [string]$uplinkName, [bool]$routerMode, [bool]$vrMode)

    # 0. refuse if another hotspot holds the radio
    if (-not $script:HasNetAdapter) {
        Log 'Get-NetAdapter is not available - this Windows image is missing standard'
        Log 'network components; the hotspot cannot be managed here.'
        return $false
    }
    $busy = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'Direct|Hosted' -and $_.Status -eq 'Up' }
    if ($busy) {
        Log "Another hotspot adapter is UP ($($busy[0].InterfaceDescription))."
        Log "Stop MyPublicWiFi (or any other hotspot app) first - one hotspot per radio."
        return $false
    }
    $ssid = $ssid.Trim()
    if ($ssid.Length -lt 1) { Log 'SSID must be set.'; return $false }
    if ($pass -notmatch '^[!-~]{8,63}$') {
        Log 'Password must be 8-63 printable ASCII characters (WPA2 rule).'
        return $false
    }

    # 0b. router mode: the chosen subnet must not collide with any live
    # uplink subnet, or NAT/forwarding silently break (two interfaces
    # inside one /24). Refuse with a clear message instead.
    if ($routerMode) {
        if (-not $script:HasNetTcpIp) {
            Log 'Router mode needs the NetTCPIP cmdlets (Get-NetIPAddress / New-NetIPAddress),'
            Log 'which this Windows image is missing. Use Shared mode (Windows ICS) instead.'
            return $false
        }
        $clash = @()
        if ($script:HasNetAdapter) {
            foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi Direct|Hosted' })) {
                $ips = @()
                try { $ips = @(Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) } catch { }
                foreach ($ip in $ips) {
                    if ($ip.IPAddress -like '169.254.*') { continue }
                    # prefix-aware: a /16 uplink must block any /24 inside
                    # it, not just the identical /24
                    $plen = 24
                    try { if ($null -ne $ip.PrefixLength -and [int]$ip.PrefixLength -gt 0) { $plen = [int]$ip.PrefixLength } } catch { }
                    if (Test-SubnetOverlap "$($script:Subnet).0" 24 ([string]$ip.IPAddress) $plen) { $clash += $a.Name }
                }
            }
        }
        if ($clash.Count -gt 0) {
            Log "The hotspot subnet $($script:Subnet).0/24 overlaps the network on: $(($clash | Select-Object -Unique) -join ', ')"
            Log 'Pick a different Hotspot IP in the Internet sharing card (e.g. 192.168.50.1) and start again.'
            return $false
        }
    }

    # 1. create the Wi-Fi Direct publisher
    try {
        $script:Pub = New-Object Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher
        $script:Pub.Advertisement.IsAutonomousGroupOwnerEnabled = $true
        $legacy = $script:Pub.Advertisement.LegacySettings
        $legacy.IsEnabled = $true
        $legacy.Ssid = $ssid
        $cred = New-Object Windows.Security.Credentials.PasswordCredential
        $cred.Password = $pass
        $legacy.Passphrase = $cred
    } catch {
        Log "Wi-Fi Direct setup failed: $($_.Exception.Message)"
        return $false
    }

    # 2. start it and wait for the virtual adapter (pumping the UI so
    #    the window stays responsive - v2.1.0 froze for up to 15 s here)
    try { $script:Pub.Start() }
    catch {
        Log "Publisher could not be started: $($_.Exception.Message)"
        $script:Pub = $null
        return $false
    }
    Log "Publisher starting..."
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Invoke-UIPump 200
        if ([string]$script:Pub.Status -eq 'Aborted') {
            Log "Publisher ABORTED (driver refused the AP)."
            $script:Pub = $null
            return $false
        }
        $script:VAdapter = Get-WfdAdapter
        if ($script:VAdapter -and [string]$script:Pub.Status -eq 'Started') { break }
    }
    if (-not $script:VAdapter -or [string]$script:Pub.Status -ne 'Started') {
        Log "Access point never came up. Status: $($script:Pub.Status)"
        try { $script:Pub.Stop() } catch { }
        $script:Pub = $null
        return $false
    }
    Log "Access point is UP on adapter: $($script:VAdapter.InterfaceDescription)"
    $ch = (netsh wlan show interfaces) 2>&1 | Out-String
    $bandLine  = [regex]::Match($ch, 'Band\s*:\s*(\S+)').Groups[1].Value
    $chanLine  = [regex]::Match($ch, 'Channel\s*:\s*(\d+)').Groups[1].Value
    if (-not $chanLine) {
        # localized netsh output (e.g. Chinese) - match the words via char codes
        # so this file stays pure ASCII: 0x6CE2+0x6BB5 = bo-duan, 0x4FE1+0x9053 = xin-dao
        $patBand = [string][char]0x6CE2 + [string][char]0x6BB5
        $patChan = [string][char]0x4FE1 + [string][char]0x9053
        $bandLine = [regex]::Match($ch, $patBand + '\s*:\s*(\S+)').Groups[1].Value
        $chanLine = [regex]::Match($ch, $patChan + '\s*:\s*(\d+)').Groups[1].Value
    }
    Log "Band follows uplink: currently $bandLine channel $chanLine (5 GHz requires a 5 GHz uplink)"

    # power saving off on both adapters - always, by design
    $physWifi = Get-PhysicalWifi
    if ($physWifi) { Disable-AdapterPowerSaving $physWifi.Name }
    if ($script:VAdapter) { Disable-AdapterPowerSaving $script:VAdapter.Name }
    if ($vrMode) { Enable-VRMode }

    # runtime subnet: Router mode uses the configured one; Shared mode
    # adopts whatever Windows ICS actually assigned (detected below)
    $runSub = $script:Subnet
    $icsAddr = ''
    $script:RouterIpOk = $false

    # 3a. router mode: own NAT + own DHCP with reservations
    if ($routerMode) {
        Disable-AllIcs
        try {
            # drop leftover addresses from earlier sessions (e.g. an ICS
            # 192.168.137.1) so only the chosen subnet lives on the adapter
            $stale = @(Get-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike "$($script:Subnet).*" })
            foreach ($si in $stale) {
                try {
                    Remove-NetIPAddress -IPAddress $si.IPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -Confirm:$false -ErrorAction Stop | Out-Null
                    Log "Removed leftover address $($si.IPAddress) from the hotspot adapter"
                } catch { Log "Could not remove leftover address $($si.IPAddress): $($_.Exception.Message)" }
            }
            $existing = Get-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -eq $script:ServerIP }
            if (-not $existing) {
                New-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -IPAddress $script:ServerIP -PrefixLength 24 -ErrorAction Stop | Out-Null
            }
            Log "Router mode: $script:ServerIP/24 set on the hotspot adapter"
            $script:RouterIpOk = $true
        } catch { Log "Could not set static IP: $($_.Exception.Message)" }
        # without an address on the hotspot adapter the DHCP server
        # cannot bind and clients associate but never get online -
        # that must not be reported as a running hotspot
        if (-not $script:RouterIpOk) {
            Log 'Stopping - no address could be set on the hotspot adapter.'
            # the publisher block above already paused Wi-Fi scans when
            # VR mode was on - resume them or they stay paused while the
            # app sits at IDLE (recovered only on close/next launch)
            try { Disable-VRMode | Out-Null } catch { }
            try { $script:Pub.Stop() } catch { }
            $script:Pub = $null
            return $false
        }
        try {
            if (Get-NetNat -Name VRHotspotNAT -ErrorAction SilentlyContinue) { Remove-NetNat -Name VRHotspotNAT -Confirm:$false }
            New-NetNat -Name VRHotspotNAT -InternalIPInterfaceAddressPrefix "$($script:Subnet).0/24" -ErrorAction Stop | Out-Null
            Log "NAT created ($($script:Subnet).0/24)"
        } catch { Log "NAT creation failed: $($_.Exception.Message) - internet sharing may not work" }
        try {
            $up = Get-NetAdapter -Name $uplinkName -ErrorAction Stop
            Set-NetIPInterface -InterfaceIndex $up.InterfaceIndex -Forwarding Enabled -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $script:VAdapter.InterfaceIndex -Forwarding Enabled -ErrorAction SilentlyContinue
            Log "IP forwarding enabled on uplink + hotspot"
        } catch { Log "Forwarding setup: $($_.Exception.Message)" }

        # start the DHCP server runspace (reservations sync live afterwards)
        Stop-DhcpServer
        $sync.Leases.Clear()
        $sync.LeaseList = @()
        $sync.Stop      = $false
        $sync.Subnet    = $script:Subnet
        $sync.ServerIP  = $script:ServerIP
        $sync.PoolStart = 100; $sync.PoolEnd = 200
        $rv = Get-Reservations
        # only reservations inside the ACTIVE subnet can be honored -
        # anything else would hand the client an address it cannot use
        $rvOk = @($rv | Where-Object { $_.ip -like "$($script:Subnet).*" })
        $h = @{}
        foreach ($r in $rvOk) { $h[(Norm-Mac $r.mac)] = $r.ip }
        $sync.Reservations = $h
        $script:DhcpRun = [powershell]::Create().AddScript($DhcpSource).AddArgument($sync)
        $script:DhcpHandle = $script:DhcpRun.BeginInvoke()
        Enable-DhcpFirewallRule
        Log "Built-in DHCP started with $($rvOk.Count) reservation(s)"
        foreach ($r in $rvOk) { Log "  static: $($r.name)  $($r.mac)  -> $($r.ip)" }
        foreach ($r in @($rv | Where-Object { $_.ip -notlike "$($script:Subnet).*" })) {
            Log "  skipped (outside $($script:Subnet).x): $($r.name) $($r.ip) - re-pin it on this subnet"
        }
        if ($rv.Count -eq 0) {
            Log '  (no reservations yet - connect a device and double-click it to pin one)'
        }
    }
    # 3b. shared mode: ICS
    else {
        Disable-AllIcs
        Start-Sleep -Milliseconds 500
        $ok = Enable-IcsOnNames -uplinkName $uplinkName -privateName $script:VAdapter.Name
        if ($ok) {
            Log "ICS sharing enabled: uplink '$uplinkName' -> hotspot '$($script:VAdapter.Name)'"
            # Windows ICS defaults to 192.168.137.x but can be configured
            # otherwise - adopt whatever address it actually gave the
            # hotspot adapter so the device list tracks the right subnet
            $icsDeadline = (Get-Date).AddSeconds(12)
            $icsSub = $null
            while ((Get-Date) -lt $icsDeadline) {
                Invoke-UIPump 300
                try {
                    $ipa = Get-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                           Where-Object { $_.IPAddress -notlike '169.254.*' } | Sort-Object -Property IPAddress | Select-Object -First 1
                    if ($ipa) { $icsSub = (($ipa.IPAddress -split '\.') | Select-Object -First 3) -join '.'; $icsAddr = [string]$ipa.IPAddress; break }
                } catch { }
            }
            if ($icsSub -and $icsSub -ne $runSub) {
                $runSub = $icsSub
                Log "ICS subnet detected: $icsSub.x (adopted for the device list)"
                Log "  (the Hotspot IP box only applies to Router mode)"
            }
        }
        else {
            Log "ICS could not be enabled (Windows ICS is limited on this system)."
            Log "Tip: try Router mode instead - it does not use ICS at all."
        }
        if (@(Get-Reservations).Count -gt 0) {
            Log 'Note: static IP reservations only take effect in Router mode.'
        }
    }

    # 4. start the client tracker (device list + latency/bandwidth feed)
    $sync.RouterMode  = $routerMode
    $sync.ScanIfIndex = $script:VAdapter.InterfaceIndex
    $sync.Subnet      = $runSub
    # runtime gateway: Router mode = the configured one; Shared mode =
    # the address ICS actually put on the adapter (NOT the configured
    # router-mode IP - the tracker would filter a client holding it
    # as "our own address")
    if ($routerMode) { $sync.ServerIP = $script:ServerIP }
    elseif ($icsAddr) { $sync.ServerIP = $icsAddr }
    else { $sync.ServerIP = "$runSub.1" }
    $sync.BwIfName    = $script:VAdapter.Name
    $sync.BwIfIndex   = $script:VAdapter.InterfaceIndex
    $sync.GraceOnline = 0
    $sync.GraceRemove = 0
    $sync.Sim         = $false
    Start-ClientScan
    return $true
}

function Stop-Hotspot {
    Stop-ClientScan
    Stop-DhcpServer
    Disable-DhcpFirewallRule
    try { Get-NetNat -Name VRHotspotNAT -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false } catch { }
    try { Disable-AllIcs } catch { }
    try { Disable-VRMode | Out-Null } catch { }
    if ($script:Pub) {
        try { $script:Pub.Stop() } catch { }
        Log "Hotspot stopped."
        # wait for the virtual adapter to disappear so an immediate
        # restart is not refused by the "one hotspot per radio" check
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-WfdAdapter)) { break }
            Invoke-UIPump 150
        }
    }
    $script:Pub = $null; $script:VAdapter = $null
    $sync.Leases.Clear()
    $sync.LeaseList = @()
}

# =====================================================================
# GDI drawing helpers used by the GUI (icon + latency graph).
# Their bodies use only System.Drawing, no WinForms types, so they
# live here - outside the GUI guard - and the automated test harness
# can exercise the real shipped drawing code with mock controls.
# They reference $pbLat / $lblPing / the palette variables, which only
# exist when the GUI runs (the harness defines mocks with the same
# property names before calling).
# =====================================================================
function Make-Icon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(18, 21, 28))
    $teal = [System.Drawing.Color]::FromArgb(45, 212, 191)
    $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(64, 76, 96), 1)
    $brush = [System.Drawing.SolidBrush]::new($teal)
    $arcPen = [System.Drawing.Pen]::new($teal, 3)
    try {
        $g.DrawRectangle($borderPen, 0, 0, 31, 31)
        $g.FillEllipse($brush, 14, 23, 5, 5)
        $g.DrawArc($arcPen, 9, 18, 12, 12, 220, 100)
        $g.DrawArc($arcPen, 5, 13, 20, 20, 220, 100)
        $g.DrawArc($arcPen, 1, 8, 28, 28, 220, 100)
    } finally { $borderPen.Dispose(); $brush.Dispose(); $arcPen.Dispose(); $g.Dispose() }
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

function Draw-Sparkline {
    if (-not $pbLat -or -not $lblPing) { return }
    $w = $pbLat.Width; $h = $pbLat.Height
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    # any exception mid-draw must not leak the bitmap on every tick
    try {
        Draw-SparklineInner $bmp $g $w $h
    }
    catch {
        # keep the previous frame, dispose the half-drawn one, and say
        # so ONCE instead of silently freezing (or spamming every tick)
        if (-not $script:DrawFailLogged) {
            $script:DrawFailLogged = $true
            Log "graph drawing failed: $($_.Exception.Message)"
        }
        try { $bmp.Dispose() } catch { }
        try { $g.Dispose() } catch { }
        return
    }
    $script:DrawFailLogged = $false
    $g.Dispose()
    if ($pbLat.Image) { $pbLat.Image.Dispose() }
    $pbLat.Image = $bmp
}

function Draw-SparklineInner($bmp, $g, $w, $h) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($GraphBg)

    # two stacked zones: latency (~62%) on top, bandwidth (~32%) below
    $latTop = 4
    $latBot = [int][Math]::Round($h * 0.60)
    $bwTop  = [int][Math]::Round($h * 0.68)
    $bwBot  = $h - 4
    if (($bwBot - $bwTop) -lt 12) { $bwTop = $bwBot - 12 }
    if (($latBot - $latTop) -lt 12) { $latBot = $bwTop - 3 }
    $penBase = [System.Drawing.Pen]::new($CardBrd, 1)
    try {
        $g.DrawLine($penBase, 4, $latBot, ($w - 4), $latBot)
        $g.DrawLine($penBase, 4, ($bwTop - 3), ($w - 4), ($bwTop - 3))
    } finally { $penBase.Dispose() }

    # ---------------- latency zone ----------------
    # ToArray() takes the list's lock - a live enumeration could throw
    # if the tracker appends a sample mid-draw
    $hist = @($sync.PingHist.ToArray())
    $n = $hist.Count
    $cap = 120
    $view = @()
    if ($n -gt $cap) { $view = @($hist[($n - $cap)..($n - 1)]) } else { $view = $hist }
    $vn = $view.Count
    $tgtName = [string]$sync.TargetName
    if (-not $tgtName) { $tgtName = 'client' }

    if ($vn -gt 1) {
        $maxV = 30.0
        foreach ($v in $view) { if ($v -gt $maxV) { $maxV = [double]$v } }
        $spacing = [double]($w - 10) / [double][Math]::Max(1, ($vn - 1))
        $penLine = [System.Drawing.Pen]::new($Accent, 2)
        $penDrop = [System.Drawing.Pen]::new($Red, 2)
        $fillPts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
        $prev = [System.Drawing.PointF]::new(-1.0, -1.0)
        $zoneH = ($latBot - $latTop - 6)
        try {
            for ($i = 0; $i -lt $vn; $i++) {
                $v = [int]$view[$i]
                $x = [single](5 + $i * $spacing)
                if ($v -lt 0) {
                    $g.DrawLine($penDrop, $x, ($latTop + 2), $x, ($latBot - 1))
                    if ($fillPts.Count -gt 1) {
                        $fillPts.Add([System.Drawing.PointF]::new($fillPts[$fillPts.Count - 1].X, [single]$latBot))
                        $fillPts.Add([System.Drawing.PointF]::new($fillPts[0].X, [single]$latBot))
                        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(46, 20, 184, 166))
                        try { $g.FillPolygon($brush, $fillPts.ToArray()) } finally { $brush.Dispose() }
                    }
                    $fillPts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
                    $prev = [System.Drawing.PointF]::new(-1.0, -1.0)
                }
                else {
                    $y = [single]($latBot - 1 - ($v / $maxV) * $zoneH)
                    $pt = [System.Drawing.PointF]::new($x, $y)
                    if ($prev.X -ge 0) { $g.DrawLine($penLine, $prev, $pt) }
                    $fillPts.Add($pt)
                    $prev = $pt
                }
            }
            if ($fillPts.Count -gt 1) {
                $fillPts.Add([System.Drawing.PointF]::new($fillPts[$fillPts.Count - 1].X, [single]$latBot))
                $fillPts.Add([System.Drawing.PointF]::new($fillPts[0].X, [single]$latBot))
                $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(46, 20, 184, 166))
                try { $g.FillPolygon($brush, $fillPts.ToArray()) } finally { $brush.Dispose() }
            }
        } finally { $penLine.Dispose(); $penDrop.Dispose() }

        $pos = @($view | Where-Object { $_ -ge 0 })
        $lastV = [int]$view[$vn - 1]
        if ($lastV -ge 0) {
            $avg = 0; $mx = 0
            if ($pos.Count -gt 0) {
                $avg = [int](($pos | Measure-Object -Average).Average)
                $mx = [int](($pos | Measure-Object -Maximum).Maximum)
            }
            $lblPing.ForeColor = $BodyText
            $lblPing.Text = ('Latency to {0}:  {1} ms      (avg {2} / max {3} / last {4} s)' -f $tgtName, $lastV, $avg, $mx, $vn)
        }
        else {
            $lblPing.ForeColor = $Amber
            $lblPing.Text = ('{0} is not answering pings (idle, sleeping or disconnected)' -f $tgtName)
        }
    }
    else {
        if ($sync.PingTarget) {
            $lblPing.ForeColor = $BodyText
            $lblPing.Text = "Latency to ${tgtName}:  measuring..."
        }
        else {
            $lblPing.ForeColor = $Muted
            $lblPing.Text = 'Waiting for a connected client...'
        }
    }

    # ---------------- bandwidth zone ----------------
    # TX (to devices) = amber filled area, RX (from devices) = indigo
    # line; both autoscaled to the window maximum, -1 samples skipped.
    $bwr = @($sync.BwHistR.ToArray())
    $bwt = @($sync.BwHistT.ToArray())
    if ($bwr.Count -gt $cap) { $bwr = @($bwr[($bwr.Count - $cap)..($bwr.Count - 1)]) }
    if ($bwt.Count -gt $cap) { $bwt = @($bwt[($bwt.Count - $cap)..($bwt.Count - 1)]) }
    $bn = [Math]::Min($bwr.Count, $bwt.Count)
    $bmax = 0.5
    if ($bn -gt 1) {
        for ($i = 0; $i -lt $bn; $i++) {
            if ([double]$bwt[$i] -gt $bmax) { $bmax = [double]$bwt[$i] }
            if ([double]$bwr[$i] -gt $bmax) { $bmax = [double]$bwr[$i] }
        }
        $bsp = [double]($w - 10) / [double][Math]::Max(1, ($bn - 1))
        $bzH = ($bwBot - $bwTop - 2)
        # TX filled area
        $pts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
        for ($i = 0; $i -lt $bn; $i++) {
            $v = [double]$bwt[$i]
            $x = [single](5 + $i * $bsp)
            if ($v -ge 0) {
                $y = [single]($bwBot - ($v / $bmax) * $bzH)
                [void]$pts.Add([System.Drawing.PointF]::new($x, $y))
            }
            else {
                if ($pts.Count -gt 1) {
                    $pts.Add([System.Drawing.PointF]::new($pts[$pts.Count - 1].X, [single]$bwBot))
                    $pts.Add([System.Drawing.PointF]::new($pts[0].X, [single]$bwBot))
                    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(38, 251, 191, 36))
                    try { $g.FillPolygon($brush, $pts.ToArray()) } finally { $brush.Dispose() }
                }
                $pts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
            }
        }
        if ($pts.Count -gt 1) {
            $pts.Add([System.Drawing.PointF]::new($pts[$pts.Count - 1].X, [single]$bwBot))
            $pts.Add([System.Drawing.PointF]::new($pts[0].X, [single]$bwBot))
            $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(38, 251, 191, 36))
            try { $g.FillPolygon($brush, $pts.ToArray()) } finally { $brush.Dispose() }
        }
        # RX thin line
        $penRx = [System.Drawing.Pen]::new($BwRxFg, 1.5)
        try {
            $prevPt = $null
            for ($i = 0; $i -lt $bn; $i++) {
                $v = [double]$bwr[$i]
                $x = [single](5 + $i * $bsp)
                if ($v -ge 0) {
                    $y = [single]($bwBot - ($v / $bmax) * $bzH)
                    $pt = [System.Drawing.PointF]::new($x, $y)
                    if ($prevPt) { $g.DrawLine($penRx, $prevPt, $pt) }
                    $prevPt = $pt
                }
                else { $prevPt = $null }
            }
        } finally { $penRx.Dispose() }
    }

    # ---------------- bandwidth captions ----------------
    if ($lblBwTx -and $lblBwRx) {
        if ($sync.BwFail) {
            $lblBwTx.ForeColor = $Muted; $lblBwTx.Text = 'Bandwidth: not available on this system.'
            $lblBwRx.Text = ''
        }
        elseif (-not $sync.BwOk) {
            $lblBwTx.ForeColor = $Muted; $lblBwTx.Text = 'Bandwidth: measuring...'
            $lblBwRx.Text = ''
        }
        else {
            $lastT = -1.0; $lastR = -1.0
            for ($i = $bwt.Count - 1; $i -ge 0; $i--) { if ([double]$bwt[$i] -ge 0) { $lastT = [double]$bwt[$i]; break } }
            for ($i = $bwr.Count - 1; $i -ge 0; $i--) { if ([double]$bwr[$i] -ge 0) { $lastR = [double]$bwr[$i]; break } }
            $lblBwTx.ForeColor = $BwTxFg
            $lblBwRx.ForeColor = $BwRxFg
            if ($lastT -ge 0) { $lblBwTx.Text = ('To devices: {0:N1} Mbps  (session {1})' -f $lastT, (Format-Bytes ([double]$sync.BwTotalT))) }
            else { $lblBwTx.Text = 'To devices: waiting for a sample...' }
            if ($lastR -ge 0) { $lblBwRx.Text = ('From devices: {0:N1} Mbps  (session {1})' -f $lastR, (Format-Bytes ([double]$sync.BwTotalR))) }
            else { $lblBwRx.Text = 'From devices: waiting for a sample...' }
        }
    }

    # small in-graph tag so the two zones cannot be confused: the
    # bandwidth strip is ADAPTER-WIDE (all devices), unlike the latency
    # zone which follows the tracked device only
    try {
        $tagFont = New-Object System.Drawing.Font('Segoe UI', 6.75)
        $tagBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(165, 142, 152, 168))
        try { $g.DrawString('hotspot throughput - all devices', $tagFont, $tagBrush, 8, ($bwTop - 2)) }
        finally { $tagFont.Dispose(); $tagBrush.Dispose() }
    } catch { }
}

function Clear-Sparkline {
    if ($pbLat.Image) { $pbLat.Image.Dispose(); $pbLat.Image = $null }
    if ($lblPing) { $lblPing.ForeColor = $Muted; $lblPing.Text = 'Latency: hotspot not running.' }
    if ($lblBwTx) { $lblBwTx.ForeColor = $Muted; $lblBwTx.Text = 'Bandwidth: hotspot not running.' }
    if ($lblBwRx) { $lblBwRx.Text = '' }
}

# =====================================================================
# GUI (skipped entirely in self-test mode)
# =====================================================================
if (-not $SelfTest) {

# ---------- elevation ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show('Please run VR-Hotspot-Studio.bat as Administrator.', 'Elevation required') | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

[Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher,Windows.Devices.WiFiDirect,ContentType=WindowsRuntime] | Out-Null
# the WPA2 passphrase type lives in a different winmd - load it too,
# or New-Object may not resolve it on a stock PS 5.1 box
[Windows.Security.Credentials.PasswordCredential,Windows.Security,ContentType=WindowsRuntime] | Out-Null

# single instance: a second copy would un-pause the first one's VR mode
# at launch (crash recovery) and fight over the radio
$script:Singleton = New-Object System.Threading.Mutex($false, 'Local\VRHotspotStudio-app')
if (-not $script:Singleton.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show('VR Hotspot Studio is already running (check the system tray near the clock).', 'Already running') | Out-Null
    exit 1
}

# ---------- DPI awareness + uniform scaling ----------
# v2.2.0 placed every control at hard-coded 96-DPI pixels: on displays
# with 125-150% scaling (or an increased Windows text size) labels
# drifted onto the text boxes. The process now opts into DPI awareness
# and every coordinate, size and font below goes through SC(), so the
# window stays crisp and correctly proportioned at any scale. Labels
# also sit above their input fields now, so even a wider system font
# cannot collide with an input box.
try {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace VRhs -ErrorAction Stop | Out-Null
    [void][VRhs.Dpi]::SetProcessDPIAware()
} catch { }
$script:Scale = 1.0
try {
    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = [double]$g0.DpiX / 96.0
    $g0.Dispose()
} catch { $script:Scale = 1.0 }
if ($script:Scale -lt 0.5 -or $script:Scale -gt 4.0) { $script:Scale = 1.0 }
function SC([double]$v) { [int][Math]::Round($v * $script:Scale) }

# ---------- palette + typography (dark "VR console" look) ----------
$BgForm   = [System.Drawing.Color]::FromArgb(18, 21, 28)      # deep slate
$CardBg   = [System.Drawing.Color]::FromArgb(26, 31, 41)
$CardBrd  = [System.Drawing.Color]::FromArgb(38, 45, 58)
$InputBg  = [System.Drawing.Color]::FromArgb(35, 42, 54)
$White    = [System.Drawing.Color]::FromArgb(232, 237, 244)   # headings
$BodyText = [System.Drawing.Color]::FromArgb(170, 180, 196)
$Muted    = [System.Drawing.Color]::FromArgb(142, 152, 168)   # keeps 4.5:1 on the card background
$Accent   = [System.Drawing.Color]::FromArgb(20, 184, 166)    # teal (graph lines, borders)
$AccentHi = [System.Drawing.Color]::FromArgb(45, 212, 191)
$AccentBtn= [System.Drawing.Color]::FromArgb(15, 118, 110)    # darker teal for buttons (AA contrast)
$Green    = [System.Drawing.Color]::FromArgb(74, 222, 128)
$Red      = [System.Drawing.Color]::FromArgb(248, 113, 113)
$Amber    = [System.Drawing.Color]::FromArgb(251, 191, 36)
$GraphBg  = [System.Drawing.Color]::FromArgb(13, 16, 23)
$LogFg    = [System.Drawing.Color]::FromArgb(159, 227, 197)
$StartBg  = [System.Drawing.Color]::FromArgb(21, 128, 61)
$StartHi  = [System.Drawing.Color]::FromArgb(22, 163, 74)
$StopBg   = [System.Drawing.Color]::FromArgb(185, 28, 28)
$StopHi   = [System.Drawing.Color]::FromArgb(220, 38, 38)
$BtnBg    = [System.Drawing.Color]::FromArgb(35, 42, 54)
$BtnBgHi  = [System.Drawing.Color]::FromArgb(48, 57, 73)
$BwTxFg   = [System.Drawing.Color]::FromArgb(252, 211, 77)    # 'to devices' (graph fill + caption)
$BwRxFg   = [System.Drawing.Color]::FromArgb(129, 140, 248)   # 'from devices' (graph line + caption)

$FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', [float](14 * $script:Scale))
$FontHdr   = New-Object System.Drawing.Font('Segoe UI', [float](8.5 * $script:Scale), [System.Drawing.FontStyle]::Bold)
$FontBody  = New-Object System.Drawing.Font('Segoe UI', [float](9 * $script:Scale))
$FontBtn   = New-Object System.Drawing.Font('Segoe UI', [float](9 * $script:Scale), [System.Drawing.FontStyle]::Bold)
$FontMono  = New-Object System.Drawing.Font('Consolas', [float](8.5 * $script:Scale))

# dark context menus (a tiny renderer so the right-click menus do not
# flash white). Compiled once; if it fails we just keep the default.
$VRhsDarkMenu = $false
try {
    Add-Type -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class VRhsDarkColors : ProfessionalColorTable {
    public override Color ToolStripDropDownBackground { get { return Color.FromArgb(26, 31, 41); } }
    public override Color ImageMarginGradientBegin  { get { return Color.FromArgb(26, 31, 41); } }
    public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(26, 31, 41); } }
    public override Color ImageMarginGradientEnd    { get { return Color.FromArgb(26, 31, 41); } }
    public override Color MenuBorder                { get { return Color.FromArgb(38, 45, 58); } }
    public override Color MenuItemBorder            { get { return Color.FromArgb(20, 184, 166); } }
    public override Color MenuItemSelected          { get { return Color.FromArgb(35, 42, 54); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(35, 42, 54); } }
    public override Color MenuItemSelectedGradientEnd   { get { return Color.FromArgb(35, 42, 54); } }
    public override Color MenuItemPressedGradientBegin  { get { return Color.FromArgb(35, 42, 54); } }
    public override Color MenuItemPressedGradientEnd    { get { return Color.FromArgb(35, 42, 54); } }
    public override Color SeparatorDark              { get { return Color.FromArgb(38, 45, 58); } }
    public override Color SeparatorLight             { get { return Color.FromArgb(38, 45, 58); } }
}
public class VRhsDarkRenderer : ToolStripProfessionalRenderer {
    public VRhsDarkRenderer() : base(new VRhsDarkColors()) { }
}
'@ -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing')
    $VRhsDarkMenu = $true
} catch { $VRhsDarkMenu = $false }

# ---------- control factories ----------
# All coordinates are 96-DPI design values; SC() scales them to the
# real display DPI so nothing overlaps on scaled screens.
function New-Label([string]$text, [int]$x, [int]$y, [int]$w, $col) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = [System.Drawing.Point]::new((SC $x), (SC $y))
    $l.Size = [System.Drawing.Size]::new((SC $w), (SC 15))
    $l.ForeColor = $col; $l.Font = $FontBody; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoEllipsis = $true
    return $l
}

function New-Box([int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = [System.Drawing.Point]::new((SC $x), (SC $y))
    $t.Size = [System.Drawing.Size]::new((SC $w), (SC 24))
    $t.BackColor = $InputBg; $t.ForeColor = $White
    $t.BorderStyle = 'FixedSingle'; $t.Font = $FontBody
    return $t
}

function New-Chk([string]$text, [int]$x, [int]$y, [int]$w) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = [System.Drawing.Point]::new((SC $x), (SC $y))
    $c.Size = [System.Drawing.Size]::new((SC $w), (SC 24))
    $c.ForeColor = $BodyText; $c.BackColor = $CardBg; $c.Font = $FontBody
    return $c
}

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $bg, $fg, $hover) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = [System.Drawing.Point]::new((SC $x), (SC $y))
    $b.Size = [System.Drawing.Size]::new((SC $w), (SC $h))
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $bg; $b.ForeColor = $fg
    if ($hover) { $b.FlatAppearance.MouseOverBackColor = $hover; $b.FlatAppearance.MouseDownBackColor = $hover }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $FontBtn
    return $b
}

function Set-DoubleBuffered($c) {
    try {
        $pi = $c.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($pi) { $pi.SetValue($c, $true, $null) }
    } catch { }
}

# a flat "card": panel with a 1px border painted on it and a small
# uppercase section header baked in (the header zone y 8-24 is reserved:
# card content starts at y 22 or lower)
function New-Card([string]$title, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = [System.Drawing.Point]::new((SC $x), (SC $y))
    $p.Size = [System.Drawing.Size]::new((SC $w), (SC $h))
    $p.BackColor = $CardBg
    Set-DoubleBuffered $p
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $title.ToUpper([System.Globalization.CultureInfo]::InvariantCulture)
    $t.Location = [System.Drawing.Point]::new((SC 14), (SC 8))
    $t.Size = [System.Drawing.Size]::new((SC ($w - 28)), (SC 16))
    $t.ForeColor = $Muted; $t.Font = $FontHdr
    $t.BackColor = [System.Drawing.Color]::Transparent
    $p.Controls.Add($t)
    $p.Add_Paint({
        $s = $args[0]; $e = $args[1]
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = [System.Drawing.Pen]::new($script:CardBrd, 1)
        try {
            $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
        } finally { $pen.Dispose() }
    })
    return $p
}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "VR Hotspot Studio v$AppVersion"
$form.StartPosition = 'CenterScreen'
$form.BackColor = $BgForm
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $FontBody
$wantW = 600
# fit the window to the screen: on small displays the form scrolls
# instead of cutting off the log and status bar. The window is widened
# in scroll mode so the vertical scrollbar does not push a horizontal
# one onto the cards.
$wantH = 1042
$formHpx = SC $wantH
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if (($wa.Height - 16) -lt $formHpx) {
        $formHpx = $wa.Height - 16
        $form.AutoScroll = $true
        $form.AutoScrollMinSize = [System.Drawing.Size]::new((SC 568), (SC 1002))
        $wantW = 620
    }
} catch { }
$form.Size = [System.Drawing.Size]::new((SC $wantW), $formHpx)
Set-DoubleBuffered $form

# ---------- header band ----------
$title = New-Object System.Windows.Forms.Label
$title.Text = 'VR HOTSPOT STUDIO'
$title.Location = [System.Drawing.Point]::new((SC 16), (SC 10))
$title.Size = [System.Drawing.Size]::new((SC 400), (SC 30))
$title.ForeColor = $White; $title.Font = $FontTitle
$form.Controls.Add($title)
$sub = New-Label 'standalone Wi-Fi Direct hotspot - no tethering stack' 16 42 424 $Muted
$form.Controls.Add($sub)

# status pill (custom-painted capsule on the right of the header)
$script:PillText  = 'IDLE'
$script:PillColor = $Muted
$script:PillPanel = New-Object System.Windows.Forms.Panel
$script:PillPanel.Location = [System.Drawing.Point]::new((SC 448), (SC 14))
$script:PillPanel.Size = [System.Drawing.Size]::new((SC 132), (SC 30))
$script:PillPanel.Font = $FontBtn
Set-DoubleBuffered $script:PillPanel
$script:PillPanel.Add_Paint({
    $s = $args[0]; $e = $args[1]
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $c = $script:PillColor
    $tint = [System.Drawing.Color]::FromArgb(42, $c.R, $c.G, $c.B)
    $w = $s.Width - 1; $h = $s.Height - 1
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $rr = [int](($h - 1) / 2)
    $path.AddArc(0, 0, (2 * $rr), (2 * $rr), 180, 90)
    $path.AddArc(($w - 2 * $rr), 0, (2 * $rr), (2 * $rr), 270, 90)
    $path.AddArc(($w - 2 * $rr), ($h - 2 * $rr), (2 * $rr), (2 * $rr), 0, 90)
    $path.AddArc(0, ($h - 2 * $rr), (2 * $rr), (2 * $rr), 90, 90)
    $path.CloseFigure()
    $brush = [System.Drawing.SolidBrush]::new($tint)
    $pen = [System.Drawing.Pen]::new($c, 1)
    try {
        $g.FillPath($brush, $path)
        $g.DrawPath($pen, $path)
        $rect = [System.Drawing.Rectangle]::new(0, 0, ($w + 1), ($h + 1))
        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($g, $script:PillText, $s.Font, $rect, [System.Drawing.Color]::FromArgb(235, $c.R, $c.G, $c.B), $flags)
    } finally { $brush.Dispose(); $pen.Dispose(); $path.Dispose() }
})
$form.Controls.Add($script:PillPanel)

function Set-Pill([string]$text, $color) {
    $script:PillText = $text
    $script:PillColor = $color
    if ($script:PillPanel) { $script:PillPanel.Invalidate() }
}

# ---------- card: hotspot ----------
# left column: SSID + password (labels ABOVE the boxes - v2.2.0 put
# them to the left with a 6 px overlap on 'Password')
$gHot = New-Card 'Hotspot' 16 58 568 126
$form.Controls.Add($gHot)
$gHot.Controls.Add((New-Label 'SSID' 16 30 100 $BodyText))
$tSsid = New-Box 16 46 172;  $gHot.Controls.Add($tSsid)
$gHot.Controls.Add((New-Label 'Password' 196 30 100 $BodyText))
$tPass = New-Box 196 46 172; $gHot.Controls.Add($tPass)
$cbShow = New-Chk 'Show' 372 48 56; $gHot.Controls.Add($cbShow)
$btnCopy = New-Btn 'Copy SSID + pass' 16 78 172 24 $BtnBg $White $BtnBgHi
$gHot.Controls.Add($btnCopy)
$btnStart = New-Btn 'START' 436 40 116 44 $StartBg $White $StartHi
$gHot.Controls.Add($btnStart)
$btnStop = New-Btn 'STOP' 436 90 116 30 $StopBg $White $StopHi
$btnStop.Enabled = $false
$gHot.Controls.Add($btnStop)

# ---------- card: internet sharing ----------
$gShare = New-Card 'Internet sharing' 16 192 568 158
$form.Controls.Add($gShare)
$gShare.Controls.Add((New-Label 'Uplink (adapter that has internet)' 16 30 260 $BodyText))
$cbUp = New-Object System.Windows.Forms.ComboBox
$cbUp.Location = [System.Drawing.Point]::new((SC 16), (SC 46))
$cbUp.Size = [System.Drawing.Size]::new((SC 300), (SC 24))
$cbUp.BackColor = $InputBg; $cbUp.ForeColor = $White
$cbUp.FlatStyle = 'Flat'; $cbUp.Font = $FontBody
$cbUp.DropDownStyle = 'DropDownList'
$gShare.Controls.Add($cbUp)
$cbRouter = New-Chk 'Router mode (own DHCP + static IP reservations)' 16 74 440
$gShare.Controls.Add($cbRouter)
$gShare.Controls.Add((New-Label 'Hotspot IP' 24 104 90 $BodyText))
$tIp = New-Box 118 100 130
$tIp.Font = $FontMono
$gShare.Controls.Add($tIp)
$lblIpErr = New-Label 'Router mode - applies on next start' 258 104 294 $Muted
$gShare.Controls.Add($lblIpErr)
$cbAuto = New-Chk 'Auto-start on launch' 16 130 160
$gShare.Controls.Add($cbAuto)
$cbVR = New-Chk 'VR mode (pause Windows Wi-Fi scans while running)' 184 130 368
$gShare.Controls.Add($cbVR)

# ---------- card: connected devices ----------
$gClients = New-Card 'Connected devices' 16 356 568 156
$form.Controls.Add($gClients)
$lvClients = New-Object System.Windows.Forms.ListView
$lvClients.Location = [System.Drawing.Point]::new((SC 14), (SC 26))
$lvClients.Size = [System.Drawing.Size]::new((SC 540), (SC 88))
$lvClients.View = 'Details'; $lvClients.FullRowSelect = $true
$lvClients.HeaderStyle = 'Nonclickable'
$lvClients.HideSelection = $false
$lvClients.BackColor = $InputBg; $lvClients.ForeColor = $White
$lvClients.BorderStyle = 'FixedSingle'; $lvClients.Font = $FontBody
Set-DoubleBuffered $lvClients
foreach ($c in @(@('Device', 200), @('IP', 105), @('MAC', 150), @('Status', 85))) {
    [void]$lvClients.Columns.Add($c[0], (SC $c[1]))
}
$gClients.Controls.Add($lvClients)
$btnPin = New-Btn 'Pin static IP' 14 122 122 26 $AccentBtn $White $AccentHi
$gClients.Controls.Add($btnPin)
$gClients.Controls.Add((New-Label 'double-click pins its static IP - right-click for more options' 146 126 408 $Muted))

# ---------- card: static IP reservations ----------
$gResv = New-Card 'Static IP reservations (Router mode)' 16 518 568 156
$form.Controls.Add($gResv)
$lvResv = New-Object System.Windows.Forms.ListView
$lvResv.Location = [System.Drawing.Point]::new((SC 14), (SC 26))
$lvResv.Size = [System.Drawing.Size]::new((SC 404), (SC 88))
$lvResv.View = 'Details'; $lvResv.FullRowSelect = $true
$lvResv.HeaderStyle = 'Nonclickable'
$lvResv.HideSelection = $false
$lvResv.BackColor = $InputBg; $lvResv.ForeColor = $White
$lvResv.BorderStyle = 'FixedSingle'; $lvResv.Font = $FontBody
Set-DoubleBuffered $lvResv
foreach ($c in @(@('Name', 150), @('MAC', 150), @('IP', 104))) {
    [void]$lvResv.Columns.Add($c[0], (SC $c[1]))
}
$gResv.Controls.Add($lvResv)
$gResv.Controls.Add((New-Label 'reserved devices keep their address across reconnects' 14 126 404 $Muted))
$btnResAdd = New-Btn 'Add' 432 26 122 32 $AccentBtn $White $AccentHi
$gResv.Controls.Add($btnResAdd)
$btnResDel = New-Btn 'Remove' 432 64 122 32 $BtnBg $White $BtnBgHi
$gResv.Controls.Add($btnResDel)

# ---------- card: latency + bandwidth ----------
$gLat = New-Card 'Latency + bandwidth' 16 680 568 172
$form.Controls.Add($gLat)
$lblPing = New-Label 'Latency: waiting for a hotspot...' 14 25 330 $BodyText
$gLat.Controls.Add($lblPing)
$cbTrack = New-Object System.Windows.Forms.ComboBox
$cbTrack.Location = [System.Drawing.Point]::new((SC 356), (SC 25))
$cbTrack.Size = [System.Drawing.Size]::new((SC 198), (SC 24))
$cbTrack.BackColor = $InputBg; $cbTrack.ForeColor = $White
$cbTrack.FlatStyle = 'Flat'; $cbTrack.Font = $FontBody
$cbTrack.DropDownStyle = 'DropDownList'
$gLat.Controls.Add($cbTrack)
$pbLat = New-Object System.Windows.Forms.PictureBox
$pbLat.Location = [System.Drawing.Point]::new((SC 14), (SC 53))
$pbLat.Size = [System.Drawing.Size]::new((SC 540), (SC 84))
$pbLat.BackColor = $GraphBg
$pbLat.BorderStyle = 'FixedSingle'
$gLat.Controls.Add($pbLat)
$lblBwTx = New-Label '' 14 144 266 $BwTxFg
$gLat.Controls.Add($lblBwTx)
$lblBwRx = New-Label '' 286 144 268 $BwRxFg
$gLat.Controls.Add($lblBwRx)

# ---------- card: log ----------
$gLog = New-Card 'Log' 16 858 568 112
$form.Controls.Add($gLog)
$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Location = [System.Drawing.Point]::new((SC 14), (SC 26))
$tbLog.Size = [System.Drawing.Size]::new((SC 540), (SC 76))
$tbLog.Multiline = $true; $tbLog.ScrollBars = 'Vertical'
$tbLog.ReadOnly = $true
$tbLog.BackColor = $GraphBg
$tbLog.ForeColor = $LogFg
$tbLog.BorderStyle = 'FixedSingle'; $tbLog.Font = $FontMono
$gLog.Controls.Add($tbLog)

# ---------- status strip ----------
$status = New-Object System.Windows.Forms.Label
$status.Text = 'Idle - hotspot not running.'
$status.Location = [System.Drawing.Point]::new((SC 16), (SC 978))
$status.Size = [System.Drawing.Size]::new((SC 568), (SC 18))
$status.ForeColor = $BodyText; $status.Font = $FontBtn
$status.AutoEllipsis = $true
$form.Controls.Add($status)

# =====================================================================
# app icon, system tray
# (Make-Icon / Draw-Sparkline / Clear-Sparkline are defined in the
#  core section above so the test harness can exercise them too)
# =====================================================================
$script:AppIcon = Make-Icon
$form.Icon = $script:AppIcon

function Show-MainForm {
    $form.WindowState = 'Normal'
    $form.Show()
    $form.Activate()
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $script:AppIcon
$notifyIcon.Text = 'VR Hotspot Studio'
$notifyIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
if ($VRhsDarkMenu) { $trayMenu.Renderer = [VRhsDarkRenderer]::new() }
[void]$trayMenu.Items.Add('Open VR Hotspot Studio')
[void]$trayMenu.Items.Add('Start hotspot')
[void]$trayMenu.Items.Add('Stop hotspot')
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add('Exit')
foreach ($it in $trayMenu.Items) { $it.ForeColor = $BodyText }
$notifyIcon.ContextMenuStrip = $trayMenu
$trayMenu.Items[0].Add_Click({ Show-MainForm })
$trayMenu.Items[1].Add_Click({ Invoke-StartHotspot })
$trayMenu.Items[2].Add_Click({ Invoke-StopHotspot })
$trayMenu.Items[4].Add_Click({ $form.Close() })
$notifyIcon.Add_DoubleClick({ Show-MainForm })
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') { $form.Hide() }
})

# =====================================================================
# reservation dialog (built ONCE at top level and reused - event
# handlers must be created at top level so they can see the controls)
# =====================================================================
$dlgForm = New-Object System.Windows.Forms.Form
$dlgForm.Text = 'Pin a static IP'
$dlgForm.Size = [System.Drawing.Size]::new((SC 376), (SC 348))
$dlgForm.StartPosition = 'CenterParent'
$dlgForm.BackColor = $BgForm
$dlgForm.FormBorderStyle = 'FixedDialog'
$dlgForm.MaximizeBox = $false
$dlgForm.MinimizeBox = $false
$dlgForm.Font = $FontBody
$dlgByText = @{}

$dlgForm.Controls.Add((New-Label 'Copy details from a connected device:' 16 14 330 $BodyText))
$dlgPick = New-Object System.Windows.Forms.ComboBox
$dlgPick.Location = [System.Drawing.Point]::new((SC 16), (SC 34))
$dlgPick.Size = [System.Drawing.Size]::new((SC 336), (SC 24))
$dlgPick.BackColor = $InputBg; $dlgPick.ForeColor = $White
$dlgPick.FlatStyle = 'Flat'; $dlgPick.Font = $FontBody
$dlgPick.DropDownStyle = 'DropDownList'
$dlgForm.Controls.Add($dlgPick)

$dlgForm.Controls.Add((New-Label 'Device name' 16 72 200 $BodyText))
$dlgT1 = New-Box 16 92 336; $dlgForm.Controls.Add($dlgT1)
$dlgForm.Controls.Add((New-Label 'MAC address (any format)' 16 126 200 $BodyText))
$dlgT2 = New-Box 16 146 336; $dlgForm.Controls.Add($dlgT2)
$dlgForm.Controls.Add((New-Label 'Static IP (suggested: .50 - .99 range)' 16 180 260 $BodyText))
$dlgT3 = New-Box 16 200 160; $dlgForm.Controls.Add($dlgT3)
$dlgErr = New-Object System.Windows.Forms.Label
$dlgErr.Text = ''
$dlgErr.Location = [System.Drawing.Point]::new((SC 16), (SC 230))
$dlgErr.Size = [System.Drawing.Size]::new((SC 336), (SC 18))
$dlgErr.ForeColor = $Red; $dlgErr.Font = $FontBody
$dlgForm.Controls.Add($dlgErr)

$dlgSave = New-Btn '&Save' 252 258 100 30 $AccentBtn $White $AccentHi
$dlgForm.Controls.Add($dlgSave)
$dlgCancel = New-Btn '&Cancel' 16 258 100 30 $BtnBg $White $BtnBgHi
$dlgForm.Controls.Add($dlgCancel)
$dlgForm.AcceptButton = $dlgSave
$dlgForm.CancelButton = $dlgCancel
# =====================================================================
# latency + bandwidth graph drawing lives in the core section (see the
# note there); this file only wires the GUI around it
# =====================================================================

# =====================================================================
# list rendering (diff-based: rows are updated in place keyed by MAC,
# never cleared + rebuilt - that is what made v2.1.0 blink)
# =====================================================================
function Refresh-ResvList {
    $lvResv.Items.Clear()
    foreach ($r in (Get-Reservations)) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.name)
        $dispMac = Format-MacDisp $r.mac
        [void]$item.SubItems.Add($dispMac)
        [void]$item.SubItems.Add($r.ip)
        $lvResv.Items.Add($item) | Out-Null
    }
}

function Refresh-Uplinks {
    $sel = $cbUp.SelectedItem
    $cbUp.Items.Clear()
    $adapters = @(Get-UplinkAdapters)
    foreach ($a in $adapters) { [void]$cbUp.Items.Add($a.Name) }
    if ($sel -and $cbUp.Items.Contains($sel)) { $cbUp.SelectedItem = $sel }
    elseif ($cbUp.Items.Count -gt 0) { $cbUp.SelectedIndex = 0 }
    elseif ($cbUp.Items.Count -eq 0) {
        [void]$cbUp.Items.Add('(no uplink adapter found)')
        $cbUp.SelectedIndex = 0
    }
}

function Render-Clients {
    $snap = @($sync.Clients)
    $want = @{}
    foreach ($c in $snap) { $want[[string]$c.macKey] = $c }
    $have = @{}
    foreach ($it in $lvClients.Items) { $have[[string]$it.Tag] = $it }
    $lvClients.BeginUpdate()
    try {
        foreach ($k in @($have.Keys)) {
            if (-not $want.ContainsKey($k)) { [void]$lvClients.Items.Remove($have[$k]) }
        }
        foreach ($c in $snap) {
            $k = [string]$c.macKey
            $name = Resolve-DeviceName $k
            if (-not $name) { $name = 'client' }
            $it = $null
            if ($have.ContainsKey($k)) { $it = $have[$k] }
            if ($it) {
                if ($it.Text -ne $name) { $it.Text = $name }
                if ($it.SubItems[1].Text -ne $c.ip) { $it.SubItems[1].Text = $c.ip }
                if ($it.SubItems[2].Text -ne $c.macDisp) { $it.SubItems[2].Text = $c.macDisp }
                if ($it.SubItems[3].Text -ne $c.status) { $it.SubItems[3].Text = $c.status }
            }
            else {
                $it = New-Object System.Windows.Forms.ListViewItem($name)
                $it.Tag = $k
                [void]$it.SubItems.Add($c.ip)
                [void]$it.SubItems.Add($c.macDisp)
                [void]$it.SubItems.Add($c.status)
                [void]$lvClients.Items.Add($it)
            }
            $col = $Green
            if ($c.status -eq 'reconnect') { $col = $Amber }
            if ($c.status -eq 'offline') { $col = $Muted }
            if ($it.ForeColor -ne $col) { $it.ForeColor = $col }
        }
    }
    finally { $lvClients.EndUpdate() }
}

# =====================================================================
# GUI behavior
# =====================================================================
$script:Running      = $false
$script:Busy         = $false
$script:ClosePending = $false
$script:SparkIdle    = $false
$script:ScanDeadLogged = $false
# graph target picker state
$script:TrackByText  = @{}
$script:TrackLastKey = $null    # $null (not '') so the FIRST tick always
                                # populates the Auto entry (v2.2.0 left the
                                # dropdown blank until a device appeared)
$script:TrackSync    = $false

# validate + apply the Hotspot IP box. Returns $true when the value is
# valid; on a subnet CHANGE it updates $script:Subnet (used from the
# next start on), flags out-of-subnet reservations and logs it.
function Update-ServerIPField([bool]$fromUser) {
    $sub = Test-ServerIP $tIp.Text
    if ($null -eq $sub) {
        $lblIpErr.ForeColor = $Red
        $lblIpErr.Text = $script:IpErr
        return $false
    }
    $canon = [string]$script:IpCanonical
    if ($canon) { $tIp.Text = $canon }
    if ($sub -ne $script:Subnet) {
        $script:Subnet = $sub
        $script:ServerIP = $canon
        if ($fromUser) {
            $outside = @((Get-Reservations) | Where-Object { $_.ip -notlike "$sub.*" })
            Log "Hotspot subnet set to $canon/24 (Router mode - applies on next start)"
            if ($outside.Count -gt 0) {
                Log "  note: $($outside.Count) reservation(s) are outside $sub.x - they are ignored until re-pinned"
            }
        }
    }
    else { $script:ServerIP = $canon }
    $lblIpErr.ForeColor = $Muted
    $lblIpErr.Text = 'Router mode - applies on next start'
    return $true
}

# keep the Hotspot IP box + its hint in step with the Router-mode
# checkbox. Called from the CheckedChanged handler AND once at init -
# WinForms only raises CheckedChanged on an actual change, so a saved
# routerMode=false used to leave the box wrongly enabled at startup.
function Sync-RouterUI {
    $tIp.Enabled = [bool]$cbRouter.Checked
    if ($cbRouter.Checked) {
        [void](Update-ServerIPField $false)
    }
    else {
        $lblIpErr.ForeColor = $Muted
        $lblIpErr.Text = 'Router mode only - in Shared mode Windows ICS picks the subnet'
    }
}

function Invoke-StartHotspot {
    if ($script:Running) { Log 'Hotspot is already running.'; return }
    if ($script:Busy) { Log 'Still finishing a start/stop - try again in a moment.'; return }
    $uplink = $cbUp.SelectedItem
    if (-not $uplink -or ([string]$uplink -like '*(no uplink*')) {
        Log 'No uplink selected - is any network adapter connected?'
        return
    }
    if ($cbRouter.Checked -and -not (Update-ServerIPField $false)) {
        Log 'Fix the Hotspot IP in the Internet sharing card before starting.'
        $status.Text = 'Start blocked - invalid Hotspot IP.'
        $status.ForeColor = $Red
        return
    }
    $script:Busy = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled = $false
    Set-Pill 'STARTING' $Amber
    $status.Text = 'Bringing the hotspot up...'
    $status.ForeColor = $BodyText
    try {
        Save-Settings $tSsid.Text $tPass.Text $uplink ([bool]$cbRouter.Checked) ([bool]$cbVR.Checked) ([bool]$cbAuto.Checked) $tIp.Text.Trim()
        $ok = Start-Hotspot -ssid $tSsid.Text -pass $tPass.Text -uplinkName $uplink -routerMode ([bool]$cbRouter.Checked) -vrMode ([bool]$cbVR.Checked)
        $script:Running = $ok
        if ($ok) {
            Set-Pill 'RUNNING' $Green
            $status.Text = "RUNNING  -  SSID '$($tSsid.Text)'"
            $status.ForeColor = $BodyText
            $btnStop.Enabled = $true
            try { $notifyIcon.ShowBalloonTip(2500, 'Hotspot started', "SSID: $($tSsid.Text)", [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
        }
        else {
            Set-Pill 'IDLE' $Muted
            # surface the failure next to the button, not only in the log
            # (strip the log timestamp so it fits and reads clean)
            $ls = $sync.Log.ToArray()
            $lastLog = ''
            if ($ls.Count -gt 0) { $lastLog = ([string]$ls[$ls.Count - 1] -replace '^\d{2}:\d{2}:\d{2}\s+', '') }
            $status.Text = "Start failed - $lastLog"
            $status.ForeColor = $Red
            $btnStart.Enabled = $true
        }
    }
    finally {
        $script:Busy = $false
        if (-not $script:Running) { $btnStart.Enabled = $true; $btnStop.Enabled = $false }
        if ($script:ClosePending) { $form.Close() }
    }
}

function Invoke-StopHotspot {
    if ($script:Busy) { Log 'Still finishing a start/stop - try again in a moment.'; return }
    if (-not $script:Running) { return }
    $script:Busy = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled = $false
    Set-Pill 'STOPPING' $Amber
    $status.Text = 'Stopping the hotspot...'
    try {
        Stop-Hotspot
        $script:Running = $false
        Set-Pill 'IDLE' $Muted
        $status.Text = 'Idle - hotspot not running.'
        $status.ForeColor = $BodyText
        Clear-Sparkline
        Refresh-Uplinks
        try { $notifyIcon.ShowBalloonTip(2000, 'Hotspot stopped', 'Wi-Fi scans resumed.', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
    finally {
        $script:Busy = $false
        $btnStart.Enabled = $true
        $btnStop.Enabled = $false
        if ($script:ClosePending) { $form.Close() }
    }
}

# open the reservation dialog, optionally pre-filled from a device.
# Pre-fill rule: a device whose current IP is inside the dynamic pool
# (100-200) gets a clean .50-.99 suggestion instead, so reservations
# do not squat on pool addresses by accident.
function Show-ReserveDialog([string]$preMac, [string]$preIp, [string]$preName) {
    $dlgErr.Text = ''
    $dlgPick.SelectedIndex = -1
    $dlgPick.Items.Clear()
    $dlgByText.Clear()
    foreach ($c in @($sync.Clients)) {
        $nm = Resolve-DeviceName ([string]$c.macKey)
        if (-not $nm) { $nm = 'client' }
        $txt = ('{0}    {1}    {2}' -f $nm, $c.ip, $c.macDisp)
        $dlgByText[$txt] = $c
        [void]$dlgPick.Items.Add($txt)
    }
    if ($preName) { $dlgT1.Text = $preName } else { $dlgT1.Text = '' }
    if ($preMac)  { $dlgT2.Text = (Format-MacDisp $preMac) } else { $dlgT2.Text = '' }
    $useIp = ''
    if ($preIp -and ($preIp -match '\.(\d+)$')) {
        $oct = [int]$Matches[1]
        if ($oct -gt 0 -and $oct -lt 100) { $useIp = $preIp }
    }
    if (-not $useIp) { $useIp = Get-SuggestedIP }
    $dlgT3.Text = $useIp
    [void]$dlgForm.ShowDialog($form)
}

$btnStart.Add_Click({ Invoke-StartHotspot })
$btnStop.Add_Click({ Invoke-StopHotspot })
$cbShow.Add_Click({ $tPass.UseSystemPasswordChar = -not $cbShow.Checked })

$btnCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText("SSID: $($tSsid.Text)   Password: $($tPass.Text)")
        Log 'SSID and password copied to the clipboard.'
    } catch { Log "Clipboard copy failed: $($_.Exception.Message)" }
})

# ----- hotspot IP field -----
$tIp.Add_Leave({ [void](Update-ServerIPField $true) })
$cbRouter.Add_CheckedChanged({ Sync-RouterUI })

# ----- reservation dialog wiring -----
$dlgPick.Add_SelectedIndexChanged({
    $c = $dlgByText[[string]$dlgPick.Text]
    if ($c) {
        $nm = Resolve-DeviceName ([string]$c.macKey)
        if ($nm) { $dlgT1.Text = $nm }
        $dlgT2.Text = [string]$c.macDisp
        if ($dlgT3.Text -eq '' -or $dlgT3.Text -eq "$(Get-ActiveSubnet).50") { $dlgT3.Text = (Get-SuggestedIP) }
    }
})

$dlgSave.Add_Click({
    $dlgErr.Text = ''
    $macN = Norm-Mac $dlgT2.Text
    $ipObj = $null
    $ipOk = [System.Net.IPAddress]::TryParse($dlgT3.Text.Trim(), [ref]$ipObj)
    if (-not $macN -or $macN -notmatch '^[0-9a-f]{12}$') { $dlgErr.Text = 'MAC address does not look valid.'; return }
    if (-not $ipOk) { $dlgErr.Text = 'Static IP is not a valid IP address.'; return }
    # validate against the subnet the hotspot is RUNNING on (Shared mode
    # adopts the ICS one), not the not-yet-applied one from the IP box
    $actSub = Get-ActiveSubnet
    if ($dlgT3.Text.Trim() -notlike "$actSub.*") { $dlgErr.Text = "IP must be in $actSub.x (same subnet as the hotspot)."; return }
    # the gateway is no longer necessarily .1 - block whatever the
    # hotspot PC itself answers on
    $gws = @("$actSub.1", "$($script:Subnet).1")
    if ($script:ServerIP) { $gws += $script:ServerIP }
    if ($script:Running -and [string]$sync.ServerIP) { $gws += [string]$sync.ServerIP }
    if ($gws -contains $dlgT3.Text.Trim()) { $dlgErr.Text = "$($dlgT3.Text.Trim()) is the hotspot PC itself - pick another address."; return }
    $oct = -1
    if ($dlgT3.Text.Trim() -match '\.(\d+)$') { $oct = [int]$Matches[1] }
    if ($oct -eq 0 -or $oct -eq 255) { $dlgErr.Text = 'That address is the network or broadcast address - pick another.'; return }
    if ($oct -ge 100 -and $oct -le 200) { $dlgErr.Text = ".$oct is inside the dynamic pool (.100-.200) - pick .2-.99 so dynamic clients cannot collide."; return }
    $list = @(Get-Reservations | Where-Object { $_.mac -ne $macN })
    $clash = @($list | Where-Object { $_.ip -eq $dlgT3.Text.Trim() })
    if ($clash.Count -gt 0) { $dlgErr.Text = "IP $($dlgT3.Text.Trim()) is already reserved for $($clash[0].name)."; return }
    foreach ($le in @($sync.LeaseList)) {
        if ([string]$le.ip -eq $dlgT3.Text.Trim() -and (Norm-Mac ([string]$le.mac)) -ne $macN) {
            $dlgErr.Text = "IP $($dlgT3.Text.Trim()) is currently leased by another device ($($le.mac))."; return
        }
    }
    $nm = $dlgT1.Text.Trim()
    if (-not $nm) { $nm = 'device' }
    $list += [pscustomobject]@{ mac = $macN; ip = $dlgT3.Text.Trim(); name = $nm }
    Set-Reservations $list
    Refresh-ResvList
    Log "Reservation saved: $nm $($dlgT2.Text) -> $($dlgT3.Text.Trim())"
    if ($script:Running -and $cbRouter.Checked) {
        Log '  Applies immediately - reconnect the device (Wi-Fi off/on) to pick it up.'
    }
    $dlgForm.Close()
})
$dlgCancel.Add_Click({ $dlgForm.Close() })

$btnResAdd.Add_Click({ Show-ReserveDialog '' '' '' })

$btnResDel.Add_Click({
    if ($lvResv.SelectedItems.Count -eq 0) { return }
    $mac = $lvResv.SelectedItems[0].SubItems[1].Text
    $ans = [System.Windows.Forms.MessageBox]::Show($form, "Remove the reservation for $mac ?", 'Remove reservation', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $list = @(Get-Reservations | Where-Object { $_.mac -ne (Norm-Mac $mac) })
    Set-Reservations $list
    Refresh-ResvList
    Log "Reservation removed: $mac"
})

# ----- click a connected device straight into the reservations -----
$btnPin.Add_Click({
    if ($lvClients.SelectedItems.Count -gt 0) {
        $it = $lvClients.SelectedItems[0]
        Show-ReserveDialog ([string]$it.Tag) $it.SubItems[1].Text $it.Text
    }
    else {
        Show-ReserveDialog '' '' ''
    }
})

$lvClients.Add_DoubleClick({
    if ($lvClients.SelectedItems.Count -eq 0) { return }
    $it = $lvClients.SelectedItems[0]
    Show-ReserveDialog ([string]$it.Tag) $it.SubItems[1].Text $it.Text
})

$ctxClients = New-Object System.Windows.Forms.ContextMenuStrip
if ($VRhsDarkMenu) { $ctxClients.Renderer = [VRhsDarkRenderer]::new() }
$ctxPin = $ctxClients.Items.Add('Pin static IP for this device')
$ctxWatch = $ctxClients.Items.Add('Watch latency (ping this device)')
[void]$ctxClients.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$ctxCopy = $ctxClients.Items.Add('Copy MAC address')
foreach ($it in $ctxClients.Items) { $it.ForeColor = $BodyText }
$lvClients.ContextMenuStrip = $ctxClients

# WinForms does NOT select the row under the cursor on right-click -
# do it ourselves so the menu always acts on the row the user sees
$lvClients.Add_MouseDown({
    $mev = $args[1]
    if ($mev.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $hit = $lvClients.HitTest($mev.X, $mev.Y)
        if ($hit.Item) { $hit.Item.Selected = $true }
    }
})
$ctxClients.Add_Opening({
    $on = ($lvClients.SelectedItems.Count -gt 0)
    $ctxPin.Enabled = $on
    $ctxWatch.Enabled = $on
    $ctxCopy.Enabled = $on
})

$ctxPin.Add_Click({
    if ($lvClients.SelectedItems.Count -eq 0) { return }
    $it = $lvClients.SelectedItems[0]
    Show-ReserveDialog ([string]$it.Tag) $it.SubItems[1].Text $it.Text
})

# point the graph at a device: sets the tracker's target + lock, then
# mirrors the choice into the visible Track dropdown
function Watch-ClientByTag([string]$macKey) {
    $ip = $null; $nm = $null
    foreach ($c in @($sync.Clients)) {
        if ([string]$c.macKey -eq $macKey) { $ip = [string]$c.ip; $nm = Resolve-DeviceName $macKey; break }
    }
    if (-not $ip) { return }
    if (-not $nm) { $nm = 'client' }
    $sync.PingTarget = $ip
    $sync.TargetMac = $macKey
    $sync.TargetName = $nm
    $sync.TargetLocked = $true
    $sync.PingHist.Clear()
    # force the next tick to rebuild the dropdown: a Watch click that
    # lands before the device set changed would otherwise leave the
    # combo showing a stale selection forever
    $script:TrackLastKey = $null
    $script:TrackSync = $true
    try {
        foreach ($tk in @($script:TrackByText.Keys)) {
            if ([string]$script:TrackByText[$tk] -eq $macKey) { $cbTrack.SelectedItem = $tk; break }
        }
    } finally { $script:TrackSync = $false }
    Log "Latency graph is now tracking $nm ($ip) - switch devices in the Track list or right-click."
}

$ctxWatch.Add_Click({
    if ($lvClients.SelectedItems.Count -eq 0) { return }
    $it = $lvClients.SelectedItems[0]
    Watch-ClientByTag ([string]$it.Tag)
})

$ctxCopy.Add_Click({
    if ($lvClients.SelectedItems.Count -eq 0) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($lvClients.SelectedItems[0].SubItems[2].Text)
        Log 'MAC address copied to the clipboard.'
    } catch { Log "Clipboard copy failed: $($_.Exception.Message)" }
})

# ----- graph target dropdown (the visible device picker) -----
$cbTrack.Add_SelectedIndexChanged({
    if ($script:TrackSync) { return }
    $txt = [string]$cbTrack.SelectedItem
    if (-not $txt) { return }
    if ($txt -like 'Auto*') {
        $sync.TargetLocked = $false
        $sync.PingTarget = $null
        Log 'Graph tracking: automatic (first connected device).'
        return
    }
    $macKey = [string]$script:TrackByText[$txt]
    if ($macKey) { Watch-ClientByTag $macKey }
})

# refresh the Track dropdown when the device set changes (guarded by
# TrackSync so the programmatic selection cannot retrigger the handler)
function Update-TrackCombo {
    $devKey = ''
    foreach ($c in @($sync.Clients)) { $devKey += ('{0}|{1};' -f $c.macKey, $c.ip) }
    if ($devKey -eq $script:TrackLastKey) { return }
    $script:TrackLastKey = $devKey
    $script:TrackSync = $true
    try {
        $selMac = ''
        if ($cbTrack.SelectedIndex -gt 0 -and $cbTrack.SelectedItem) {
            $selMac = [string]$script:TrackByText[[string]$cbTrack.SelectedItem]
        }
        $cbTrack.Items.Clear()
        $script:TrackByText = @{}
        [void]$cbTrack.Items.Add('Auto (first connected device)')
        foreach ($c in @($sync.Clients)) {
            $nm = Resolve-DeviceName ([string]$c.macKey)
            if (-not $nm) { $nm = 'client' }
            $txt = ('{0}  ({1})' -f $nm, $c.ip)
            $script:TrackByText[$txt] = [string]$c.macKey
            [void]$cbTrack.Items.Add($txt)
        }
        $pickIdx = 0
        $wantMac = $selMac
        if (-not $wantMac -and $sync.TargetLocked) { $wantMac = [string]$sync.TargetMac }
        if ($wantMac) {
            $items = @($cbTrack.Items)
            foreach ($tk in @($script:TrackByText.Keys)) {
                if ([string]$script:TrackByText[$tk] -eq $wantMac) {
                    $pickIdx = [Array]::IndexOf($items, $tk)
                    break
                }
            }
        }
        if ($pickIdx -lt 0) { $pickIdx = 0 }
        $cbTrack.SelectedIndex = $pickIdx
    }
    finally { $script:TrackSync = $false }
}

# =====================================================================
# poll timer: log tail, publisher health, device list, latency +
# bandwidth graph, track dropdown, status
# =====================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    # ---- log tail (rollover-safe: the log trims 300 -> 200 lines and
    # the old "lines shown" counter would freeze the view after a trim).
    # ToArray() snapshots under the lock - enumerating the synchronized
    # list live could throw if a runspace logs mid-enumeration.
    $lastShown = 0
    try { $lastShown = [int]$tbLog.Tag } catch { }
    $logSnap = $sync.Log.ToArray()
    if ($lastShown -gt $logSnap.Count) { $lastShown = 0 }
    # only follow the tail when the reader was already at the bottom -
    # replacing the text while scrolled up would yank the view away
    $atEnd = ($tbLog.Text.Length -le 2) -or ($tbLog.SelectionStart -ge ($tbLog.Text.Length - 2))
    if ($atEnd -and $logSnap.Count -gt $lastShown) {
        $tbLog.Lines = [string[]]@($logSnap | Select-Object -Last 40)
        $tbLog.SelectionStart = $tbLog.Text.Length
        $tbLog.ScrollToCaret()
        $tbLog.Tag = $logSnap.Count
    }

    # keep the graph's device dropdown in step with the live device set
    Update-TrackCombo

    if ($script:Busy) { return }

    if (-not $script:Running) {
        Render-Clients
        if (-not $script:SparkIdle) { Clear-Sparkline; $script:SparkIdle = $true }
        if ($cbTrack.Enabled) { $cbTrack.Enabled = $false }
        return
    }
    if (-not $cbTrack.Enabled) { $cbTrack.Enabled = $true }

    # ---- tracker liveness: a dead runspace must not freeze silently ----
    if ($script:ScanHandle -and $script:ScanHandle.IsCompleted -and -not $script:ScanDeadLogged) {
        $script:ScanDeadLogged = $true
        Log 'Client tracker stopped unexpectedly - the device list is frozen.'
        Log 'Restart the hotspot to restore live tracking.'
        $status.Text = 'WARNING: device tracker died - restart the hotspot.'
        $status.ForeColor = $Red
    }

    # ---- publisher health ----
    if ($script:Pub) {
        $st = [string]$script:Pub.Status
        if ($st -eq 'Aborted' -or $st -eq 'Stopped') {
            $script:Busy = $true
            try {
                Log "Publisher state: $st - hotspot lost."
                Stop-Hotspot
                $script:Running = $false
                Set-Pill 'LOST' $Red
                $status.Text = 'Hotspot LOST - restart it.'
                $status.ForeColor = $Red
                Clear-Sparkline
                Refresh-Uplinks
                $btnStart.Enabled = $true
                $btnStop.Enabled = $false
                try { $notifyIcon.ShowBalloonTip(3000, 'Hotspot lost', 'The access point stopped - restart it from the app.', [System.Windows.Forms.ToolTipIcon]::Error) } catch { }
            }
            finally { $script:Busy = $false }
            return
        }
    }

    # ---- device list + latency/bandwidth graph (both sharing modes) ----
    Render-Clients
    Draw-Sparkline
    $script:SparkIdle = $false

    $cl = @($sync.Clients)
    $on = @($cl | Where-Object { $_.status -eq 'connected' }).Count
    $vrOn = 'OFF'
    if ((Test-Path $VrFlagFile) -or (Test-Path $VrFlagAlt)) { $vrOn = 'ON' }
    $status.Text = ("RUNNING  |  SSID {0}  |  {1} device(s), {2} responsive  |  VR mode {3}" -f $tSsid.Text, $cl.Count, $on, $vrOn)
    $status.ForeColor = $BodyText
})

$form.Add_FormClosing({
    $e = $args[1]
    if ($script:Busy) {
        $e.Cancel = $true
        $script:ClosePending = $true
        Log 'Close requested - finishing the current operation first...'
        return
    }
    if ($script:Running) {
        $ans = [System.Windows.Forms.MessageBox]::Show($form, 'The hotspot is running. Stop it and exit VR Hotspot Studio?', 'Hotspot is live', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
    }
    # latch Busy and stop the timer FIRST so the DoEvents pumps inside
    # Stop-Hotspot cannot re-enter tick handlers or a second close
    $script:Busy = $true
    $timer.Stop()
    # persist the current settings (a Hotspot IP edit used to be lost
    # when the user closed without starting)
    $upName = [string]$cbUp.SelectedItem
    if (-not $upName -or $upName -like '*(no uplink*') { $upName = '' }
    try { Save-Settings $tSsid.Text $tPass.Text $upName ([bool]$cbRouter.Checked) ([bool]$cbVR.Checked) ([bool]$cbAuto.Checked) $tIp.Text.Trim() } catch { }
    if ($script:Running) { Stop-Hotspot }
    Stop-ClientScan
    Stop-DhcpServer
    try { Disable-VRMode | Out-Null } catch { }
    $notifyIcon.Visible = $false
    try { $notifyIcon.Dispose() } catch { }
    try { if ($script:AppIcon) { $script:AppIcon.Dispose() } } catch { }
})

# ---------- init ----------
$cfg = Load-Settings
if ($cfg) {
    $tSsid.Text = [string]$cfg.ssid
    $tPass.Text = [string]$cfg.pass
    $cbRouter.Checked = [bool]$cfg.routerMode
    if ($null -ne $cfg.vrmode) { $cbVR.Checked = [bool]$cfg.vrmode } else { $cbVR.Checked = $true }
    $cbAuto.Checked = [bool]$cfg.autostart
}
else {
    $tSsid.Text = 'VR-Link'
    $tPass.Text = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
    $cbVR.Checked = $true
}
$tPass.UseSystemPasswordChar = $true
# hotspot IP: remembered setting or the 192.168.137.1 default. Applying
# it here (before any start) also fixes $script:Subnet so reservation
# suggestions and validation already use the chosen subnet.
$ipCfg = '192.168.137.1'
if ($cfg -and $cfg.serverIp) { $ipCfg = [string]$cfg.serverIp }
$tIp.Text = $ipCfg
[void](Update-ServerIPField $false)
# ...and put the IP box into the right enable/disable state for the
# loaded Router-mode setting (CheckedChanged does not fire on its own
# when the saved value equals the default)
Sync-RouterUI
Refresh-Uplinks
Refresh-ResvList

# crash recovery: if the app died while VR mode had scans paused, resume them
if (Disable-VRMode) {
    Log 'Crash recovery: Wi-Fi scans had been left paused - resumed now.'
}
# same idea for the DHCP firewall rule: a crash would have left the
# inbound UDP 67 allow-rule behind
Disable-DhcpFirewallRule

Log "Welcome to VR Hotspot Studio v$AppVersion."
Log 'This hotspot uses Wi-Fi Direct (wlansvc), not the broken'
Log 'Windows tethering stack - it works even though Settings cannot.'
Log 'One hotspot per radio: stop MyPublicWiFi before starting this.'
Log 'Tip: double-click a connected device to pin a static IP for it.'
Log 'Tip: pick which device the graph follows from the Track list.'
Log 'Tip: red bars are missed pings; the lower graph strip is the total'
Log '     throughput of the whole hotspot (all devices).'
if ($cfg -and $cfg.uplink -and $cbUp.Items.Contains($cfg.uplink)) { $cbUp.SelectedItem = $cfg.uplink }

$form.Add_Shown({
    if ($cbAuto.Checked) {
        Log 'Auto-start enabled - bringing the hotspot up...'
        Invoke-StartHotspot
    }
})

$timer.Start()
[void]$form.ShowDialog()

}   # end if (-not $SelfTest)
