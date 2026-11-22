<#
=====================================================================
 VR-Hotspot-Studio.ps1  v2.1.0
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
     be added or removed while the hotspot is running.

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
 reservations, VR-mode flag handling, the DHCP server) can be
 exercised by an automated test harness on any machine.
=====================================================================
#>

$ErrorActionPreference = 'Continue'
$SelfTest   = ($env:VRHS_SELFTEST -eq '1')
$AppVersion = '2.1.0'

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
$sync               = [hashtable]::Synchronized(@{})
$sync.Log           = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.Leases        = [hashtable]::Synchronized(@{})
$sync.Reservations  = @{}
$sync.Stop          = $false
$sync.StopMonitor   = $false
$sync.PingTarget    = $null
$sync.PingHist      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:MonitorRun  = $null
$script:MonitorHandle = $null

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
    param($ssid, $pass, $uplink, $routerMode, $vrmode, $autostart)
    try {
        $o = [pscustomobject]@{ ssid = $ssid; pass = $pass; uplink = $uplink; routerMode = $routerMode; vrmode = $vrmode; autostart = $autostart }
        $o | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch { Log "Could not save settings: $($_.Exception.Message)" }
}

function Norm-Mac([string]$m) {
    return (($m -replace '[:-]', '') -replace '\s', '').ToLower()
}

function Load-Reservations {
    if (-not (Test-Path $ResvFile)) { return @() }
    try {
        $out = @(Import-Csv $ResvFile | ForEach-Object {
            [pscustomobject]@{ mac = (Norm-Mac ([string]$_.mac)); ip = ([string]$_.ip); name = ([string]$_.name) }
        })
        return $out
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
    # normalize MACs so the cache, the CSV and the DHCP table all use the
    # same key format (v2.0.0 mixed formats, which broke matching)
    $list = @($list | ForEach-Object {
        [pscustomobject]@{ mac = (Norm-Mac ([string]$_.mac)); ip = ([string]$_.ip); name = ([string]$_.name) }
    })
    Save-Reservations $list
    $script:ResvCache = $list
    $h = @{}
    foreach ($r in $list) { $h[$r.mac] = $r.ip }
    $sync.Reservations = $h
}

function Get-UplinkAdapters {
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wi-Fi Direct|Hosted|Tailscale|Loopback' } |
        Sort-Object -Property @{Expression = { if ($_.InterfaceDescription -like '*802.11*') { 0 } else { 1 } }}
}

function Get-WfdAdapter {
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Wi-Fi Direct' -and $_.Status -ne 'Disconnected' } |
        Select-Object -First 1
}

function Get-PhysicalWifi {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -like '*802.11*' } | Select-Object -First 1
}

function Disable-AdapterPowerSaving([string]$name) {
    try {
        Disable-NetAdapterPowerManagement -Name $name -NoRestart -ErrorAction Stop | Out-Null
        Log "Power saving disabled on '$name' (always off in this app, by design)"
    } catch { Log "Could not disable power saving on '$name': $($_.Exception.Message)" }
}

# =====================================================================
# VR mode (pause WLAN AutoConfig background scans = dropout fix)
# =====================================================================
function Enable-VRMode {
    $w = Get-PhysicalWifi
    if (-not $w) { Log 'VR mode: no physical Wi-Fi adapter found - scans not paused.'; return }
    netsh wlan set autoconfig enabled=no interface="$($w.Name)" 2>&1 | Out-Null
    $flagWritten = $false
    try { Set-Content -Path $VrFlagFile -Value $w.Name -Encoding ASCII -ErrorAction Stop; $flagWritten = $true }
    catch {
        # read-only install folder (e.g. extracted under Program Files) - fall back to %TEMP%
        try { Set-Content -Path $VrFlagAlt -Value $w.Name -Encoding ASCII -ErrorAction Stop; $flagWritten = $true } catch { }
    }
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
        # guard both ends: a zero-length or truncated option must yield an
        # empty array (the old slice with a descending range returned junk)
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
    # option 53: message type
    $o.Add(53); $o.Add(1); $o.Add($msgType)
    # option 54: server identifier
    $o.Add(54); $o.Add(4); foreach ($b in $m) { $o.Add($b) }
    # option 51: lease time 12h, 58/59: renewal (T1) / rebind (T2)
    $o.Add(51); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([uint32]43200)) { $o.Add($b) }
    $o.Add(58); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([uint32]21600)) { $o.Add($b) }
    $o.Add(59); $o.Add(4); foreach ($b in [BitConverter]::GetBytes([uint32]37800)) { $o.Add($b) }
    # option 1: subnet mask
    $o.Add(1); $o.Add(4); foreach ($b in (IPBytes '255.255.255.0')) { $o.Add($b) }
    # option 3: router
    $o.Add(3); $o.Add(4); foreach ($b in $m) { $o.Add($b) }
    # option 6: DNS
    $dns = @(IPBytes '1.1.1.1') + @(IPBytes '8.8.8.8')
    $o.Add(6); $o.Add($dns.Count); foreach ($b in $dns) { $o.Add($b) }
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

function Get-FreeIP([string]$macKey, [string]$macDisp) {
    # reservations are read LIVE from $sync.Reservations so the GUI can
    # add/remove them while the hotspot runs
    if ($sync.Reservations) {
        foreach ($k in @($sync.Reservations.Keys)) {
            if ((MacKey ([string]$k)) -eq $macKey) { return [string]$sync.Reservations[$k] }
        }
    }
    if ($leases.ContainsKey($macDisp)) { return $leases[$macDisp] }
    # an outstanding OFFER must be honored - otherwise the REQUEST for the
    # address we just offered would count the offer as "used" and get NAKed
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
    return
}

$dst = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($bcast), $cport)
while (-not $sync.Stop) {
    # expire stale offers so a DISCOVER that was never followed by a
    # REQUEST cannot permanently eat a pool address
    foreach ($k in @($offerTime.Keys)) {
        if (((Get-Date) - $offerTime[$k]).TotalSeconds -gt 60) { $offers.Remove($k); $offerTime.Remove($k) }
    }
    $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
    $req = $null
    try { $req = $udp.Receive([ref]$ep) } catch { continue }
    if ($null -eq $req -or $req.Length -lt 240) { continue }
    # magic cookie must be present, otherwise this is not DHCP
    if ($req[236] -ne 99 -or $req[237] -ne 130 -or $req[238] -ne 83 -or $req[239] -ne 99) { continue }
    $macDisp = MacStr $req[28..43]
    $macKey  = MacKey $macDisp
    $opts = Read-Options $req
    $msgType = 0
    if ($opts.ContainsKey(53) -and $opts[53].Count -ge 1) { $msgType = [int]$opts[53][0] }

    if ($msgType -eq 1) {
        # DISCOVER -> OFFER
        $offer = Get-FreeIP $macKey $macDisp
        if ($offer) {
            $offers[$macDisp] = $offer
            $offerTime[$macDisp] = Get-Date
            try { $udp.Send((New-Reply $req $offer 2 $ip), 300, $dst) | Out-Null; Log "OFFER $offer to $macDisp" }
            catch { Log "OFFER send failed: $($_.Exception.Message)" }
        } else { Log "POOL FULL - no address for $macDisp" }
    }
    elseif ($msgType -eq 3) {
        # REQUEST -> ACK / NAK
        # if the client is SELECTING a different server, this REQUEST is
        # not ours - stay silent per RFC 2131
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
            $offers.Remove($macDisp)
            $offerTime.Remove($macDisp)
            try { $udp.Send((New-Reply $req $assigned 5 $ip), 300, $dst) | Out-Null } catch { }
            $name = ''
            if ($opts.ContainsKey(12) -and $opts[12].Count -gt 0) { $name = [System.Text.Encoding]::ASCII.GetString($opts[12]) }
            Log "ACK $assigned to $macDisp $name"
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
        Log "DECLINE $macDisp (address conflict reported - address returned to pool)"
    }
    elseif ($msgType -eq 7) {
        # RELEASE
        if ($leases.ContainsKey($macDisp)) {
            $sync.Leases.Remove($macDisp)
            $leases.Remove($macDisp)
            Log "RELEASE $macDisp"
        }
    }
}
try { $udp.Close() } catch { }
Log "DHCP server stopped"
'@

# =====================================================================
# latency monitor source (runs in a background runspace)
# =====================================================================
$MonitorSource = @'
param($sync)
$ping = New-Object System.Net.NetworkInformation.Ping
while (-not $sync.StopMonitor) {
    $t = $sync.PingTarget
    if ($t) {
        $ms = -1
        try {
            $r = $ping.Send($t, 400)
            if ($r.Status.ToString() -eq 'Success') { $ms = [int]$r.RoundtripTime }
        } catch { }
        $sync.PingHist.Add($ms) | Out-Null
        if ($sync.PingHist.Count -gt 120) { $sync.PingHist.RemoveRange(0, $sync.PingHist.Count - 120) }
    }
    Start-Sleep -Milliseconds 500
}
'@

# =====================================================================
# start / stop logic
# =====================================================================
function Stop-DhcpServer {
    $sync.Stop = $true
    if ($script:DhcpHandle) {
        # give the runspace a moment to leave the blocking Receive call,
        # so a restart can rebind port 67 immediately (v2.0.0 race)
        $deadline = (Get-Date).AddSeconds(3)
        while (-not $script:DhcpHandle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        try { $script:DhcpRun.Stop() } catch { }
        try { $script:DhcpRun.Dispose() } catch { }
        $script:DhcpRun = $null; $script:DhcpHandle = $null
    }
}

function Start-Hotspot {
    param([string]$ssid, [string]$pass, [string]$uplinkName, [bool]$routerMode, [bool]$vrMode)

    # 0. refuse if another hotspot holds the radio
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

    # 2. start it and wait for the virtual adapter
    $script:Pub.Start()
    Log "Publisher starting..."
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ([string]$script:Pub.Status -eq 'Aborted') { Log "Publisher ABORTED (driver refused the AP)."; return $false }
        $script:VAdapter = Get-WfdAdapter
        if ($script:VAdapter -and [string]$script:Pub.Status -eq 'Started') { break }
    }
    if (-not $script:VAdapter) {
        Log "Virtual adapter never appeared. Status: $($script:Pub.Status)"
        try { $script:Pub.Stop() } catch { }
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

    # 3a. router mode: own NAT + own DHCP with reservations
    if ($routerMode) {
        Disable-AllIcs
        try {
            $existing = Get-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -like "$($script:Subnet).*" }
            if (-not $existing) {
                New-NetIPAddress -InterfaceIndex $script:VAdapter.InterfaceIndex -IPAddress $script:ServerIP -PrefixLength 24 -ErrorAction Stop | Out-Null
            }
            Log "Router mode: $script:ServerIP/24 set on the hotspot adapter"
        } catch { Log "Could not set static IP: $($_.Exception.Message)" }
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
        $sync.Stop      = $false
        $sync.Subnet    = $script:Subnet
        $sync.ServerIP  = $script:ServerIP
        $sync.PoolStart = 100; $sync.PoolEnd = 200
        $rv = Get-Reservations
        $h = @{}
        foreach ($r in $rv) { $h[(Norm-Mac $r.mac)] = $r.ip }
        $sync.Reservations = $h
        $script:DhcpRun = [powershell]::Create().AddScript($DhcpSource).AddArgument($sync)
        $script:DhcpHandle = $script:DhcpRun.BeginInvoke()
        Log "Built-in DHCP started with $($rv.Count) reservation(s)"
        foreach ($r in $rv) { Log "  static: $($r.name)  $($r.mac)  -> $($r.ip)" }
        if ($rv.Count -eq 0) {
            Log '  (no reservations yet - add some under "Static IP reservations")'
        }
    }
    # 3b. shared mode: ICS
    else {
        Disable-AllIcs
        Start-Sleep -Milliseconds 500
        $ok = Enable-IcsOnNames -uplinkName $uplinkName -privateName $script:VAdapter.Name
        if ($ok) { Log "ICS sharing enabled: uplink '$uplinkName' -> hotspot '$($script:VAdapter.Name)'" }
        else {
            Log "ICS could not be enabled (Windows ICS is limited on this system)."
            Log "Tip: try Router mode instead - it does not use ICS at all."
        }
        if (@(Get-Reservations).Count -gt 0) {
            Log 'Note: static IP reservations only take effect in Router mode.'
        }
    }
    return $true
}

function Stop-Hotspot {
    Stop-DhcpServer
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
            Start-Sleep -Milliseconds 250
        }
    }
    $script:Pub = $null; $script:VAdapter = $null
    $sync.Leases.Clear()
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

$dark   = [System.Drawing.Color]::FromArgb(32, 32, 36)
$darker = [System.Drawing.Color]::FromArgb(43, 43, 48)
$accent = [System.Drawing.Color]::FromArgb(0, 120, 215)
$white  = [System.Drawing.Color]::White
$gray   = [System.Drawing.Color]::FromArgb(180, 180, 180)
$green  = [System.Drawing.Color]::FromArgb(63, 195, 128)
$red    = [System.Drawing.Color]::FromArgb(232, 72, 72)
$font   = New-Object System.Drawing.Font('Segoe UI', 9)
$fontB  = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)

function New-Label([string]$text, [int]$x, [int]$y, [int]$w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20); $l.ForeColor = $gray; $l.Font = $font
    return $l
}
function New-Box([int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 24)
    $t.BackColor = $darker; $t.ForeColor = $white; $t.BorderStyle = 'FixedSingle'; $t.Font = $font
    return $t
}
function New-Group([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = "  $text  "; $g.Location = New-Object System.Drawing.Point($x, $y)
    $g.Size = New-Object System.Drawing.Size($w, $h)
    $g.ForeColor = $gray; $g.BackColor = $dark; $g.Font = $font
    return $g
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "VR Hotspot Studio v$AppVersion"
$form.StartPosition = 'CenterScreen'
$form.BackColor = $dark
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
# fit the window to the screen: on small displays the form scrolls
# instead of cutting off the log and status bar (v2.0.0 was a fixed
# 580x1032 which overflowed 768p/900p laptops)
$wantH = 1032
$formH = $wantH
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($wa.Height - 16 -lt $wantH) {
        $formH = $wa.Height - 16
        $form.AutoScroll = $true
        $form.AutoScrollMinSize = New-Object System.Drawing.Size(564, 1000)
    }
} catch { }
$form.Size = New-Object System.Drawing.Size(580, $formH)

# ---------- title ----------
$title = New-Object System.Windows.Forms.Label
$title.Text = 'VR Hotspot Studio'
$title.Location = New-Object System.Drawing.Point(20, 14)
$title.Size = New-Object System.Drawing.Size(420, 28)
$title.ForeColor = $white; $title.Font = $fontB
$form.Controls.Add($title)
$sub = New-Label 'Standalone Wi-Fi Direct hotspot - no Windows Mobile Hotspot needed' 20 42 520
$form.Controls.Add($sub)

# ---------- hotspot group ----------
$gHot = New-Group 'Hotspot' 16 66 544 118
$form.Controls.Add($gHot)
$lSsid = New-Label 'SSID' 14 30 60;   $gHot.Controls.Add($lSsid)
$tSsid = New-Box 80 27 180;            $gHot.Controls.Add($tSsid)
$lPass = New-Label 'Password' 14 64 60; $gHot.Controls.Add($lPass)
$tPass = New-Box 80 61 180;            $gHot.Controls.Add($tPass)
$cbShow = New-Object System.Windows.Forms.CheckBox
$cbShow.Text = 'show'; $cbShow.Location = New-Object System.Drawing.Point(270, 62)
$cbShow.Size = New-Object System.Drawing.Size(60, 22); $cbShow.ForeColor = $gray
$cbShow.BackColor = $dark; $cbShow.Font = $font
$cbShow.Add_Click({ $tPass.UseSystemPasswordChar = -not $cbShow.Checked })
$gHot.Controls.Add($cbShow)
$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Copy SSID+pass'
$btnCopy.Location = New-Object System.Drawing.Point(270, 24)
$btnCopy.Size = New-Object System.Drawing.Size(104, 26)
$btnCopy.FlatStyle = 'Flat'; $btnCopy.BackColor = $darker; $btnCopy.ForeColor = $white; $btnCopy.Font = $font
$gHot.Controls.Add($btnCopy)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'START HOTSPOT'
$btnStart.Location = New-Object System.Drawing.Point(380, 24)
$btnStart.Size = New-Object System.Drawing.Size(150, 44)
$btnStart.BackColor = $green; $btnStart.ForeColor = [System.Drawing.Color]::Black
$btnStart.FlatStyle = 'Flat'; $btnStart.Font = $fontB
$gHot.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'STOP'
$btnStop.Location = New-Object System.Drawing.Point(380, 72)
$btnStop.Size = New-Object System.Drawing.Size(150, 34)
$btnStop.BackColor = $red; $btnStop.ForeColor = $white
$btnStop.FlatStyle = 'Flat'; $btnStop.Font = $font
$gHot.Controls.Add($btnStop)

# ---------- sharing group ----------
$gShare = New-Group 'Internet sharing' 16 190 544 112
$form.Controls.Add($gShare)
$lUp = New-Label 'Uplink' 14 30 60; $gShare.Controls.Add($lUp)
$cbUp = New-Object System.Windows.Forms.ComboBox
$cbUp.Location = New-Object System.Drawing.Point(80, 27)
$cbUp.Size = New-Object System.Drawing.Size(220, 24)
$cbUp.BackColor = $darker; $cbUp.ForeColor = $white; $cbUp.FlatStyle = 'Flat'; $cbUp.Font = $font
$gShare.Controls.Add($cbUp)
$cbRouter = New-Object System.Windows.Forms.CheckBox
$cbRouter.Text = 'Router mode (own DHCP + static IP reservations)'
$cbRouter.Location = New-Object System.Drawing.Point(14, 58)
$cbRouter.Size = New-Object System.Drawing.Size(430, 22)
$cbRouter.ForeColor = $gray; $cbRouter.BackColor = $dark; $cbRouter.Font = $font
$gShare.Controls.Add($cbRouter)
$cbAuto = New-Object System.Windows.Forms.CheckBox
$cbAuto.Text = 'Auto-start on launch'
$cbAuto.Location = New-Object System.Drawing.Point(14, 84)
$cbAuto.Size = New-Object System.Drawing.Size(180, 22)
$cbAuto.ForeColor = $gray; $cbAuto.BackColor = $dark; $cbAuto.Font = $font
$gShare.Controls.Add($cbAuto)
$cbVR = New-Object System.Windows.Forms.CheckBox
$cbVR.Text = 'VR mode (pause Windows Wi-Fi scans while running)'
$cbVR.Location = New-Object System.Drawing.Point(210, 84)
$cbVR.Size = New-Object System.Drawing.Size(330, 22)
$cbVR.ForeColor = $gray; $cbVR.BackColor = $dark; $cbVR.Font = $font
$gShare.Controls.Add($cbVR)

# ---------- clients group ----------
$gClients = New-Group 'Connected devices' 16 318 544 150
$form.Controls.Add($gClients)
$lvClients = New-Object System.Windows.Forms.ListView
$lvClients.Location = New-Object System.Drawing.Point(14, 24)
$lvClients.Size = New-Object System.Drawing.Size(516, 112)
$lvClients.View = 'Details'; $lvClients.FullRowSelect = $true
$lvClients.BackColor = $darker; $lvClients.ForeColor = $white
$lvClients.BorderStyle = 'FixedSingle'; $lvClients.Font = $font
foreach ($c in @(@('Name', 180), @('IP', 120), @('MAC', 160))) {
    [void]$lvClients.Columns.Add($c[0], $c[1])
}
$gClients.Controls.Add($lvClients)

# ---------- reservations group ----------
$gResv = New-Group 'Static IP reservations (Router mode)' 16 474 544 150
$form.Controls.Add($gResv)
$lvResv = New-Object System.Windows.Forms.ListView
$lvResv.Location = New-Object System.Drawing.Point(14, 24)
$lvResv.Size = New-Object System.Drawing.Size(400, 112)
$lvResv.View = 'Details'; $lvResv.FullRowSelect = $true
$lvResv.BackColor = $darker; $lvResv.ForeColor = $white
$lvResv.BorderStyle = 'FixedSingle'; $lvResv.Font = $font
foreach ($c in @(@('Name', 120), @('MAC', 150), @('IP', 110))) {
    [void]$lvResv.Columns.Add($c[0], $c[1])
}
$gResv.Controls.Add($lvResv)

$btnResAdd = New-Object System.Windows.Forms.Button
$btnResAdd.Text = 'Add'
$btnResAdd.Location = New-Object System.Drawing.Point(424, 24)
$btnResAdd.Size = New-Object System.Drawing.Size(106, 30)
$btnResAdd.FlatStyle = 'Flat'; $btnResAdd.BackColor = $accent; $btnResAdd.ForeColor = $white; $btnResAdd.Font = $font
$gResv.Controls.Add($btnResAdd)
$btnResDel = New-Object System.Windows.Forms.Button
$btnResDel.Text = 'Remove'
$btnResDel.Location = New-Object System.Drawing.Point(424, 60)
$btnResDel.Size = New-Object System.Drawing.Size(106, 30)
$btnResDel.FlatStyle = 'Flat'; $btnResDel.BackColor = $darker; $btnResDel.ForeColor = $white; $btnResDel.Font = $font
$gResv.Controls.Add($btnResDel)

# ---------- latency group ----------
$gLat = New-Group 'Latency (live ping to the first connected client)' 16 630 544 128
$form.Controls.Add($gLat)
$lblPing = New-Label 'Latency: waiting for a client...' 14 22 500
$gLat.Controls.Add($lblPing)
$pbLat = New-Object System.Windows.Forms.PictureBox
$pbLat.Location = New-Object System.Drawing.Point(14, 44)
$pbLat.Size = New-Object System.Drawing.Size(516, 70)
$pbLat.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$pbLat.BorderStyle = 'FixedSingle'
$gLat.Controls.Add($pbLat)

# ---------- log group ----------
$gLog = New-Group 'Log' 16 766 544 190
$form.Controls.Add($gLog)
$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Location = New-Object System.Drawing.Point(14, 24)
$tbLog.Size = New-Object System.Drawing.Size(516, 152)
$tbLog.Multiline = $true; $tbLog.ScrollBars = 'Vertical'
$tbLog.ReadOnly = $true
$tbLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$tbLog.ForeColor = [System.Drawing.Color]::FromArgb(190, 220, 190)
$tbLog.BorderStyle = 'FixedSingle'; $tbLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$gLog.Controls.Add($tbLog)

# ---------- status bar ----------
$status = New-Object System.Windows.Forms.Label
$status.Text = 'Status: idle'
$status.Location = New-Object System.Drawing.Point(20, 964)
$status.Size = New-Object System.Drawing.Size(540, 24)
$status.ForeColor = $gray; $status.Font = $fontB
$form.Controls.Add($status)

# =====================================================================
# app icon, system tray, latency graph
# =====================================================================
function Make-Icon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(32, 32, 36))
    $greenIc = [System.Drawing.Color]::FromArgb(63, 195, 128)
    $brush = New-Object System.Drawing.SolidBrush $greenIc
    $g.FillEllipse($brush, 9, 21, 5, 5)
    $pen = New-Object System.Drawing.Pen $greenIc, 3
    $g.DrawArc($pen, 4, 16, 12, 12, 220, 100)
    $g.DrawArc($pen, 0, 12, 20, 20, 220, 100)
    $g.DrawArc($pen, -4, 8, 28, 28, 220, 100)
    $brush.Dispose(); $pen.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}
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
[void]$trayMenu.Items.Add('Open VR Hotspot Studio')
[void]$trayMenu.Items.Add('Start hotspot')
[void]$trayMenu.Items.Add('Stop hotspot')
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('Exit')
$notifyIcon.ContextMenuStrip = $trayMenu
$trayMenu.Items[0].Add_Click({ Show-MainForm })
$trayMenu.Items[1].Add_Click({ Invoke-StartHotspot })
$trayMenu.Items[2].Add_Click({ Invoke-StopHotspot })
$trayMenu.Items[4].Add_Click({ $form.Close() })
$notifyIcon.Add_DoubleClick({ Show-MainForm })
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') { $form.Hide() }
})

function Draw-Sparkline {
    if (-not $pbLat) { return }
    $w = $pbLat.Width; $h = $pbLat.Height
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(20, 20, 20))
    $hist = @($sync.PingHist)
    $n = $hist.Count
    if ($n -gt 1) {
        $maxV = 30
        foreach ($v in $hist) { if ($v -gt $maxV) { $maxV = $v } }
        $spacing = [double]($w - 4) / 119.0
        $penGreen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(63, 195, 128)), 2
        $penRed   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(232, 72, 72)), 2
        $prevX = -1.0; $prevY = -1.0
        for ($i = 0; $i -lt $n; $i++) {
            $v = $hist[$i]
            $x = [double]($w - 2) - ($n - 1 - $i) * $spacing
            if ($v -lt 0) {
                $g.DrawLine($penRed, [single]$x, 3, [single]$x, ($h - 4))
                $prevX = -1.0
            } else {
                $y = [double]($h - 4) - ($v / $maxV) * ($h - 10)
                if ($prevX -ge 0) { $g.DrawLine($penGreen, [single]$prevX, [single]$prevY, [single]$x, [single]$y) }
                $prevX = $x; $prevY = $y
            }
        }
        $penGreen.Dispose(); $penRed.Dispose()
        $lastV = $hist[$n - 1]
        if ($lastV -ge 0) { $lblPing.Text = ('Latency: {0} ms   (last {1} s, red = dropout)' -f $lastV, [int]($n / 2)) }
        else { $lblPing.Text = 'Latency: NO REPLY from the client' }
    } else {
        $lblPing.Text = 'Latency: waiting for a connected client...'
    }
    $g.Dispose()
    if ($pbLat.Image) { $pbLat.Image.Dispose() }
    $pbLat.Image = $bmp
}

function Clear-Sparkline {
    if ($pbLat.Image) { $pbLat.Image.Dispose(); $pbLat.Image = $null }
    if ($lblPing) { $lblPing.Text = 'Latency: hotspot not running.' }
}

# =====================================================================
# GUI behavior
# =====================================================================
function Refresh-ResvList {
    $lvResv.Items.Clear()
    foreach ($r in (Get-Reservations)) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.name)
        $dispMac = $r.mac
        if ($dispMac -match '^[0-9a-f]{12}$') {
            $dispMac = $dispMac -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6'
        }
        [void]$item.SubItems.Add($dispMac)
        [void]$item.SubItems.Add($r.ip)
        $lvResv.Items.Add($item) | Out-Null
    }
}

function Refresh-Uplinks {
    $sel = $cbUp.SelectedItem
    $cbUp.Items.Clear()
    foreach ($a in (Get-UplinkAdapters)) { [void]$cbUp.Items.Add($a.Name) }
    if ($sel -and $cbUp.Items.Contains($sel)) { $cbUp.SelectedItem = $sel }
    elseif ($cbUp.Items.Count -gt 0) { $cbUp.SelectedIndex = 0 }
}

$script:Running = $false

function Invoke-StartHotspot {
    if ($script:Running) { Log 'Hotspot is already running.'; return }
    $btnStart.Enabled = $false
    try {
        $uplink = $cbUp.SelectedItem
        if (-not $uplink) { Log 'No uplink selected.'; return }
        Save-Settings $tSsid.Text $tPass.Text $uplink ([bool]$cbRouter.Checked) ([bool]$cbVR.Checked) ([bool]$cbAuto.Checked)
        $ok = Start-Hotspot -ssid $tSsid.Text -pass $tPass.Text -uplinkName $uplink -routerMode ([bool]$cbRouter.Checked) -vrMode ([bool]$cbVR.Checked)
        $script:Running = $ok
        if ($ok) {
            $status.Text = "Status: RUNNING  -  SSID '$($tSsid.Text)'"
            $status.ForeColor = $green
            try { $notifyIcon.ShowBalloonTip(2500, 'Hotspot started', "SSID: $($tSsid.Text)", [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
        }
    } finally { $btnStart.Enabled = $true }
}

function Invoke-StopHotspot {
    Stop-Hotspot
    $script:Running = $false
    $status.Text = 'Status: idle'
    $status.ForeColor = $gray
    Clear-Sparkline
    try { $notifyIcon.ShowBalloonTip(2000, 'Hotspot stopped', 'Wi-Fi scans resumed.', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}

$btnStart.Add_Click({ Invoke-StartHotspot })
$btnStop.Add_Click({ Invoke-StopHotspot })

$btnCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText("SSID: $($tSsid.Text)   Password: $($tPass.Text)")
        Log 'SSID and password copied to the clipboard.'
    } catch { Log "Clipboard copy failed: $($_.Exception.Message)" }
})

$btnResAdd.Add_Click({
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Add reservation'; $f.Size = New-Object System.Drawing.Size(340, 300)
    $f.StartPosition = 'CenterParent'; $f.BackColor = $dark; $f.FormBorderStyle = 'FixedDialog'
    $l0 = New-Label 'Pick a connected device (fills the fields)' 12 12 300; $f.Controls.Add($l0)
    $cbPick = New-Object System.Windows.Forms.ComboBox
    $cbPick.Location = New-Object System.Drawing.Point(12, 32)
    $cbPick.Size = New-Object System.Drawing.Size(300, 24)
    $cbPick.BackColor = $darker; $cbPick.ForeColor = $white; $cbPick.FlatStyle = 'Flat'; $cbPick.Font = $font
    foreach ($it in $lvClients.Items) { [void]$cbPick.Items.Add(('{0}  {1}  {2}' -f $it.Text, $it.SubItems[1].Text, $it.SubItems[2].Text)) }
    $cbPick.Add_SelectedIndexChanged({
        $parts = ($cbPick.Text -split '\s{2,}')
        if ($parts.Count -ge 3) {
            $t2.Text = $parts[2]
            if ($parts[0] -ne 'client' -and ($parts[0] -replace '[:-]', '') -notmatch '^[0-9a-fA-F]{12}$') { $t1.Text = $parts[0] }
            if ($t3.Text -eq '192.168.137.50') { $t3.Text = $parts[1] }
        }
    })
    $f.Controls.Add($cbPick)
    $l1 = New-Label 'Device name' 12 66 100;  $f.Controls.Add($l1)
    $t1 = New-Box 12 86 300;                  $f.Controls.Add($t1)
    $l2 = New-Label 'MAC address (any format)' 12 114 200; $f.Controls.Add($l2)
    $t2 = New-Box 12 134 300;                 $f.Controls.Add($t2)
    $l3 = New-Label 'Static IP' 12 162 100;   $f.Controls.Add($l3)
    $t3 = New-Box 12 182 160;                 $f.Controls.Add($t3)
    $t3.Text = '192.168.137.50'
    $lErr = New-Label '' 12 212 300
    $lErr.ForeColor = $red
    $f.Controls.Add($lErr)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'; $ok.Location = New-Object System.Drawing.Point(236, 240)
    $ok.Size = New-Object System.Drawing.Size(76, 28); $ok.FlatStyle = 'Flat'
    $ok.BackColor = $accent; $ok.ForeColor = $white
    $ok.Add_Click({
        $lErr.Text = ''
        $macN = Norm-Mac $t2.Text
        $ipObj = $null
        $ipOk = [System.Net.IPAddress]::TryParse($t3.Text.Trim(), [ref]$ipObj)
        if (-not $macN -or $macN -notmatch '^[0-9a-f]{12}$') { $lErr.Text = 'MAC address does not look valid.'; return }
        if (-not $ipOk) { $lErr.Text = 'Static IP is not a valid IP address.'; return }
        if ($t3.Text.Trim() -notlike "$($script:Subnet).*") { $lErr.Text = "IP must be in $($script:Subnet).x (same subnet as the hotspot)."; return }
        $list = @(Get-Reservations | Where-Object { $_.mac -ne $macN })
        $clash = @($list | Where-Object { $_.ip -eq $t3.Text.Trim() })
        if ($clash.Count -gt 0) { $lErr.Text = "IP $($t3.Text.Trim()) is already reserved for $($clash[0].name)."; return }
        $nm = $t1.Text.Trim()
        if (-not $nm) { $nm = 'device' }
        $list += [pscustomobject]@{ mac = $macN; ip = $t3.Text.Trim(); name = $nm }
        Set-Reservations $list
        Refresh-ResvList
        Log "Reservation saved: $nm = $($t3.Text.Trim())"
        if ($script:Running -and $cbRouter.Checked) {
            Log '  Applies immediately - reconnect the device (Wi-Fi off/on) to pick it up.'
        }
        $f.Close()
    })
    $f.Controls.Add($ok)
    [void]$f.ShowDialog()
})

$btnResDel.Add_Click({
    if ($lvResv.SelectedItems.Count -eq 0) { return }
    $mac = $lvResv.SelectedItems[0].SubItems[1].Text
    $list = @(Get-Reservations | Where-Object { $_.mac -ne (Norm-Mac $mac) })
    Set-Reservations $list
    Refresh-ResvList
    Log "Reservation removed: $mac"
})

# poll timer: status, log, clients
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    # log tail
    $lastShown = [int]($tbLog.Tag)
    if ($null -eq $lastShown) { $lastShown = 0 }
    if ($sync.Log.Count -gt $lastShown) {
        $tbLog.Lines = @($sync.Log | Select-Object -Last 40)
        $tbLog.SelectionStart = $tbLog.Text.Length
        $tbLog.ScrollToCaret()
    }
    $tbLog.Tag = $sync.Log.Count
    if (-not $script:Running) { $sync.PingTarget = $null; return }

    # publisher health
    if ($script:Pub) {
        $st = [string]$script:Pub.Status
        if ($st -eq 'Aborted' -or $st -eq 'Stopped') {
            Log "Publisher state: $st - hotspot lost."
            Stop-Hotspot
            $script:Running = $false
            $status.Text = 'Status: LOST (restart the hotspot)'
            $status.ForeColor = $red
            $sync.PingTarget = $null
            Clear-Sparkline
            return
        }
    }
    # clients
    $lvClients.Items.Clear()
    $resv = Get-Reservations
    if ($cbRouter.Checked -and $sync.Leases.Count -gt 0) {
        foreach ($mac in @($sync.Leases.Keys)) {
            $ip = $sync.Leases[$mac]
            $name = ($resv | Where-Object { (Norm-Mac $_.mac) -eq (Norm-Mac $mac) } | Select-Object -First 1).name
            if (-not $name) { $name = $mac }
            $item = New-Object System.Windows.Forms.ListViewItem($name)
            [void]$item.SubItems.Add($ip)
            [void]$item.SubItems.Add($mac)
            $lvClients.Items.Add($item) | Out-Null
        }
    }
    elseif ($script:VAdapter) {
        try {
            $nb = Get-NetNeighbor -InterfaceIndex $script:VAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
                  Where-Object { $_.State -in @('Reachable', 'Probe', 'Stale', 'Delay') -and $_.IPAddress -like "$($script:Subnet).*" }
            foreach ($n in $nb) {
                $mac = $n.LinkLayerAddress
                if (-not $mac) { continue }
                $nm = ($resv | Where-Object { (Norm-Mac $_.mac) -eq (Norm-Mac $mac) } | Select-Object -First 1).name
                if (-not $nm) { $nm = 'client' }
                $item = New-Object System.Windows.Forms.ListViewItem($nm)
                [void]$item.SubItems.Add($n.IPAddress)
                [void]$item.SubItems.Add($mac)
                $lvClients.Items.Add($item) | Out-Null
            }
        } catch { }

        # latency target = first connected client
        if ($lvClients.Items.Count -gt 0) { $sync.PingTarget = $lvClients.Items[0].SubItems[1].Text }
        else { $sync.PingTarget = $null }
        Draw-Sparkline
    }
})

$form.Add_FormClosing({
    if ($script:Running) { Stop-Hotspot }
    $sync.StopMonitor = $true
    if ($script:MonitorHandle) {
        try { $script:MonitorRun.Stop(); $script:MonitorRun.Dispose() } catch { }
        $script:MonitorRun = $null; $script:MonitorHandle = $null
    }
    try { Disable-VRMode | Out-Null } catch { }
    $timer.Stop()
    $notifyIcon.Visible = $false
    try { $notifyIcon.Dispose() } catch { }
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
Refresh-Uplinks
Refresh-ResvList

# crash recovery: if the app died while VR mode had scans paused, resume them
if (Disable-VRMode) {
    Log 'Crash recovery: Wi-Fi scans had been left paused - resumed now.'
}

# latency monitor runspace (pings the current target twice a second)
$script:MonitorRun = [powershell]::Create().AddScript($MonitorSource).AddArgument($sync)
$script:MonitorHandle = $script:MonitorRun.BeginInvoke()

Log "Welcome to VR Hotspot Studio v$AppVersion."
Log 'This hotspot uses Wi-Fi Direct (wlansvc), not the broken'
Log 'Windows tethering stack - it works even though Settings cannot.'
Log 'One hotspot per radio: stop MyPublicWiFi before starting this.'
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
