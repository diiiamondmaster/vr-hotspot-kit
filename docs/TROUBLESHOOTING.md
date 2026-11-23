# Troubleshooting

> Note: the diagnostic/repair scripts mentioned below (Capability Check,
> Surgical Repair, etc.) were removed from the repo in v1.0.2 now that the
> app makes them unnecessary. They live in the git history under `repair/`
> in older tags (e.g. `v1.0.1`) if ever needed.

## The app

### The app will not start / a console asks to "supply values for the following parameters"
Fixed in v2.5.0: the culprit was a layout helper named `SC()` that the
built-in `sc` alias (Set-Content) silently shadowed - in PowerShell,
aliases outrank functions - so every scaled coordinate became a
`Set-Content` waiting for its mandatory value. v2.3.0 and v2.4.0 could
freeze or crash on it before the window ever opened. The launcher also
runs PowerShell with `-NonInteractive` (a prompting command fails fast
with a visible error instead of hanging), and any unhandled startup
error is written to `studio-crash.log` (next to the script, or `%TEMP%`
vrhs-crash.log if the folder is read-only) and shown in a message box.
If it happens to you: close the console, re-run
`VR-Hotspot-Studio.bat`, and if a window still does not appear, open
`studio-crash.log` - the last block contains the exact error to report
(and so does any red PowerShell text left in the console; a script that
fails to even parse exits before a log can be written).

Related hardening in v2.4.0: the administrator check uses `fltmc`
instead of `net session`, which needs the Server service - on heavily
stripped Windows images that service can be missing, and the launcher
used to loop on the elevation request instead of starting.

### The hotspot works but the connection stalls for a second every few minutes
That is Windows' WLAN AutoConfig background scanning - the radio leaves your
channel to look for other networks. The app's **VR mode** (on by default)
pauses those scans while the hotspot runs. If you are still seeing dropouts
with VR mode on, check the **latency graph**: red bars while the green line
is otherwise flat = radio-level interference; red bars with spiky green =
client-side Wi-Fi issues (distance, 2.4 GHz, power saving on the headset).

### Devices get kicked off after ~2 minutes (and the password is asked again)
That was a real bug through v2.5.0, fixed at the root in v2.6.0: a Wi-Fi
Direct access point must hold a `WiFiDirectDevice` session for every
connected client - if nobody accepts the connection, Windows silently
drops the client about two minutes after it associates. Printers,
headsets, phones - anything. Some clients then refuse to rejoin until
the password is retyped (it had not changed), and the repeated drops
also break anything that needs a steady TCP connection, which looks
like "no internet" or "the printer's web page will not load".

v2.8.0 runs a `WiFiDirectConnectionListener` and holds every client
session for as long as the hotspot runs - and the entire flow lives in
compiled C#, mirroring the official Microsoft Wi-Fi Direct sample:
the accept (`WiFiDirectDevice.FromIdAsync`) starts inside the event
handler the instant a client knocks, the connection-request object
stays alive until the accept finishes, and the held table is only
touched from that compiled code. This matters because **Windows
PowerShell 5.1's `Register-ObjectEvent` cannot subscribe to Windows
RT events at all** (it fails *non-terminatingly*, so v2.6.0 believed
it was armed while nothing listened - the "cannot subscribe to Windows
RT events" console errors), and because v2.7.0's bridge still queued
each request for the GUI timer and disposed the request object before
the accept ran, which could leave associations unaccepted and clients
dropped ~2 minutes later. The status line shows `keep-alive N` (how
many sessions are held); the log writes `[wfd]` lines for every step -
request seen, `client accepted and held open: <name>`, `keep-alive
released: <name>`, accept failures and stalls - plus a heartbeat every
two minutes with the held count. If a client is ever dropped again,
copy the `[wfd]` lines around that moment (plus any "Client keep-alive
could not be compiled" pair) into the bug report: they name the exact
stage that failed.

Division of labor: the keep-alive handles a single dropped client (it
reconnects and is re-accepted on its own); the automatic restart
("Auto-restarting the same hotspot" in the log) only triggers when the
access point itself dies.

### Windows can't find new networks / the uplink won't reconnect while the hotspot runs
That is VR mode working as designed: scans are paused for an unbroken
connection. Stop the hotspot to resume scanning. If the app crashed while
VR mode was on, simply launch it again - it detects the leftover
`vrmode.flag` and resumes scanning automatically.

### Latency graph shows "not answering pings" but the connection works
Some devices stop answering ICMP pings while idle (headsets at the menu,
phones with the screen off, printers that sleep) - the app keeps them in
the device list as long as they stay associated, and the graph goes amber.
That is honest data, not an error: start streaming and the green line comes
back. To track a different device, right-click it in Connected devices and
pick **Watch latency**. Red bars on a green line = real dropouts.

### A phantom device with MAC 00:00:00:00:00:00 (or one that "steals" a reserved IP)
Those rows are ARP probes that got no answer. When a VPN or tunnel is
running on the host (Tailscale is the common one - it scans the subnet
it routes), Windows records the probed addresses on every interface,
including the hotspot's, as neighbor entries with an all-zero MAC while
nothing answers. Through v2.6.0 the tracker happily turned those rows
into fake devices, which then appeared to fight over a real device's
reserved IP (typically the printer's, because that is the address being
probed). v2.7.0 filters all-zero MACs and unresolvable neighbor states
(`Incomplete` / `Unreachable`) at both the query and the merge step, so
phantom devices no longer appear. The probe traffic itself is harmless.

### The device list shows a device as "reconnect" or "offline"
"reconnect" (amber) = the device stopped responding but is still within
the grace window - it usually comes back on its own. "offline" (gray) = a
leased or reserved device that is currently gone; it keeps its row (and
its reservation) and comes back when it reconnects.

### "Publisher ABORTED (driver refused the AP)" right after START
Another program is already holding the Wi-Fi radio's AP role, or the Wi-Fi
radio is busy. In order:
1. Fully exit **MyPublicWiFi** (tray icon -> exit, not just "stop") and any
   other hotspot app.
2. Turn the Windows Mobile Hotspot toggle Off (Settings > Network).
3. Wait ~5 seconds, press START again.

One radio can hold exactly one hotspot - this is a hardware constraint, not
a bug.

### Devices connect but have no internet
- Check the **uplink** dropdown picked the adapter that actually has internet
  (the one connected to `ALPCC_Public` or your router).
- **Shared mode:** the `SharedAccess` (ICS) service must be running. Start it
  from an elevated PowerShell: `Start-Service SharedAccess`, then stop/start
  the hotspot.
- **Router mode:** check the log for "NAT created". If NAT creation failed,
  run `Get-NetNat` in an elevated PowerShell and remove stale entries:
  `Get-NetNat | Remove-NetNat -Confirm:$false`, then restart the hotspot.
  v2.6.0 also lists other NAT instances at start (WSL / Docker / Hyper-V
  create their own) - Windows supports exactly ONE NAT network, so a
  competing instance typically means internet sharing will not work until
  it is removed.
- **DNS check:** since v2.6.0 the log shows `[dns] relaying DNS (...)`
  lines while clients resolve names through the hotspot PC (the first
  five queries individually, then roughly one line per twenty). Queries
  flowing but pages not loading points at NAT; no `[dns]` lines across
  many lookups while a client browses points at the client's own
  configuration or a dead relay. Right-click the device and run
  **Test connection** for a quick ping + web-port check. The relay
  forwards UDP only - DNS answers too large for UDP (rare: DNSSEC, long
  TXT records) fail; clients fall back to their own resolvers on
  truncation.
- **Router mode on Windows 11 24H2+ / newer Insider builds:** the WinNAT
  component (`New-NetNat`) has known regressions on those builds. If the
  log shows "NAT creation failed" even after removing stale entries,
  switch to **Shared mode** as a fallback (and the other way if the ICS
  stack is what is broken on your machine - that is the situation this
  app was built for).
- If the PC itself lost internet while the hotspot runs, the uplink adapter
  dropped - reconnect it and stop/start the hotspot so ICS re-binds.

### Ping works but the printer's web page will not load
Separate the layers: right-click the device and run **Test connection**
(v2.6.0). It does three pings and probes TCP ports 80 / 443 / 9100, all
into the log.
- Pings fail = association/radio problem (see the keep-alive section
  above; on v2.5.0 and earlier the ~2-minute client drop was breaking
  exactly these long-lived TCP sessions while short pings recovered).
- Pings fine, port 80/443 open = the printer side: some printers only
  serve their web UI to the subnet they were configured on, or to
  specific clients.
- Pings fine, ports closed = something between: try the same page from
  another client on the hotspot, and check whether the printer is
  dual-homed (also cable-connected to another router) - dual-homed
  printers often answer ping from one interface and serve HTTP on the
  other.

### Clients list is empty even though a device is connected
The list refreshes once per second from ARP entries. Browse something on the
client device or ping it once; entries also age out. In Router mode the list
shows DHCP leases, which appear the moment a device requests an address.

### The hotspot is 2.4 GHz but I wanted 5 GHz
The Wi-Fi Direct legacy-AP API has no band selector - the channel **follows
the uplink**. Connect the PC's Wi-Fi to a 5 GHz network (check with
`netsh wlan show interfaces`: Band should say 5 GHz) and the hotspot moves
to 5 GHz too. If your 2.4-only device (older printers) can't see the
hotspot while you're on 5 GHz, either put the printer on USB/Ethernet or
switch the PC to the 2.4 GHz uplink when you need the printer online.

### VR streaming performance
Uplink and hotspot time-share one radio. Expect 300-450 Mbps through the
hotspot - far more than the 25 Mbps internet link, and enough for Virtual
Desktop / ALVR at high quality. Keep the headset in the same room as the PC.

### Does the hotspot survive a reboot?
No - and that is deliberate (an auto-start hotspot is what started this whole
saga). After a reboot, run `VR-Hotspot-Studio.bat` again. Your SSID, password
and reservations are remembered.

### Where are my settings stored?
`hotspot-settings.json` and `reservations.csv` next to the .ps1. The Wi-Fi
password is in that JSON in plain text - it's a hotspot password, treat it
accordingly. Note for updates: extracting a new release ZIP into a NEW
folder starts from scratch - a NEW random password is generated and the
reservations are gone. Extract over the old folder (or copy the two files)
to keep SSID, password and reservations; that also explains "the password
changed after an update" surprises.

## The Windows Mobile Hotspot (original feature)

### Settings says "We can't set up mobile hotspot" / toggle flips back off
On this machine the cause is a damaged icssvc tethering settings store - see
[THE-SAGA.md](THE-SAGA.md) for the full diagnosis. Short version:
`Hotspot-Capability-Check.bat` will show the real error. Options, in order:
1. **Just use VR Hotspot Studio** - it does not use the broken component.
2. Run `Hotspot-Surgical-Repair.bat` with a matching Windows 11 ISO mounted
   (DISM component-store repair, no setup.exe, keeps everything), reboot,
   then verify with `Hotspot-Capability-Check.bat`.

### "Hosted network supported: No"
Normal on the Realtek 8822CE. The legacy `netsh wlan` hotspot is gone
industry-wide; Wi-Fi Direct replaced it. Nothing to fix.

### Bluetooth audio is broken too
Separate tiny11 casualty: the `BthAvctpSvc` service is missing from the
image. The Surgical Repair (DISM from ISO) can restore it as well.
