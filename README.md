# VR Hotspot Kit

# [Download the latest release](https://github.com/diiiamondmaster/vr-hotspot-kit/releases)

Grab **`vr-hotspot-kit-vX.X.X.zip`** from the Releases page - just the
runnable files, no git needed. Extract and run
**`VR-Hotspot-Studio.bat`** as Administrator.

---

A standalone Wi-Fi hotspot app for Windows that **does not depend on the
Windows Mobile Hotspot stack at all**.

If Windows says *"We can't set up mobile hotspot"*, the toggle flips itself
back off, or `GetTetheringCapability` throws `0x83120006` / "Element not
found" - this kit is for you. The headline app sidesteps all of it.

---

## Quick start (60 seconds)

1. **Download**: grab **`vr-hotspot-kit.zip`** from the [Releases
   page](https://github.com/diiiamondmaster/vr-hotspot-kit/releases)
   (link at the top of this README too) - just the runnable files, no git
   needed. Prefer the whole codebase instead? Green **`<> Code`** button
   -> **Download ZIP**.
2. Extract the ZIP anywhere (right-click -> Extract All).
3. **Stop any other hotspot app** (MyPublicWiFi, Windows Mobile Hotspot
   toggle - one Wi-Fi radio can run only one hotspot).
4. Double-click **`VR-Hotspot-Studio.bat`** (it asks for Administrator -
   that is normal; hosting an access point requires it).
5. Set SSID + password (8+ chars), check that **Uplink** shows the adapter
   you use for internet, press **START HOTSPOT**.

That is it. The app needs no installation, no .NET downloads, no dependencies
- it is pure Windows PowerShell 5.1 that ships inside every Windows 10/11.

## What you get

- **Custom SSID + WPA2 password** (persisted between runs)
- **Shared mode** (default): internet comes along via Windows ICS -
  clients get NAT'd addresses in `192.168.137.x`
- **Router mode** (advanced): the app runs its own NAT and DHCP server with
  **per-MAC static IP reservations** - built for 3D printers and other
  devices that need a fixed address (see
  [docs/PRINTER-STATIC-IP.md](docs/PRINTER-STATIC-IP.md)). Hardened in
  v2.9.0 after field reports put almost every remaining problem here:
  the DHCP server now receives on a wildcard socket (a client's first
  DISCOVER is a broadcast, and Windows only guarantees delivery to
  wildcard-bound sockets - a specifically bound socket could miss every
  knock, which looks exactly like "kicked off, password asked again"),
  replies carry the right source IP through a dedicated send socket,
  the Windows ICS service is sidelined for the session so its own DHCP
  on port 67 cannot fight the built-in one, and a `[router]` watchdog
  checks every ~15 s that the DHCP server, DNS relay, NAT, IP
  forwarding, firewall rules and the hotspot's address are all still
  alive - repairing any of them automatically (4 repairs per incident,
  budget restored after 5 stable minutes) instead of telling you to
  restart the hotspot
- **Custom hotspot subnet** (Router mode): the **Hotspot IP** box accepts
  any private /24 - `10.x.x.x`, `172.16-31.x.x`, `192.168.x.x` - so you
  are no longer stuck on `192.168.137.x`. The app refuses to start on a
  subnet that collides with your uplink, cleans leftover addresses off
  the adapter, and skips reservations pinned to a different subnet
  (with a log line telling you which)
- **Connected-clients list** that actually stays live: a background
  tracker merges the ARP table, DHCP leases and a 1-per-second keepalive
  ping into one stable list (name / IP / MAC / status), so entries do not
  flicker when a device associates, the list keeps updating while VR mode
  is on, and devices only disappear after a grace period - leased or
  reserved devices never silently vanish (they show **offline** instead)
- **Clients stay connected** (v2.6.0; correct mechanism since v2.8.0):
  the app accepts and holds a Wi-Fi Direct session for every client -
  without one, Windows drops each client about two minutes after it
  connects (the "kicked off after a few minutes" bug that also made
  devices ask for the password again). The whole accept flow - event
  subscription, the immediate `FromIdAsync` call, the held-session
  table, the disconnect watch - runs inside a small C# keeper compiled
  at runtime, because PowerShell 5.1's own event engine cannot
  subscribe to WinRT events and its earlier hand-offs were too slow.
  The status line shows the held count as `keep-alive N`, and a
  `[wfd]` heartbeat logs the count every two minutes
- **Self-healing hotspot** (v2.6.0): if the access point ever dies, the
  app restarts the same hotspot automatically (3 attempts; the budget
  restores after 5 stable minutes), and system sleep is prevented while
  hosting - a sleeping PC looks exactly like a dead hotspot
- **Built-in DNS relay** (Router mode, v2.6.0; parallel and compiled
  since v2.9.0): clients use the hotspot PC as their resolver; the
  relay forwards to public DNS from the host side (works around uplinks
  that filter client DNS) and logs queries. It used to forward one
  query at a time - a connecting phone's burst of lookups crawled for
  seconds ("connected, no internet") - the relay is now a small C#
  class with eight forwarding workers, so a whole burst is answered in
  about one round trip
- **"Test connection" on any device** (right-click): 3 pings plus TCP
  probes of ports 80 / 443 / 9100, all logged - tells ping-but-no-web-page
  apart from a dead device
- **VR mode** (on by default): pauses Windows' background Wi-Fi scans while
  the hotspot runs - that scanning is what causes the every-few-minutes
  dropout that breaks rhythm games like Beat Saber. Scans resume
  automatically when the hotspot stops, the app closes, or on the next
  launch after a crash (crash-safe flag file)
- **Adapter power saving is always disabled** while the hotspot runs - no
  toggle, by design (Realtek power saving causes micro-stutters)
- **Auto-start on launch** (optional checkbox)
- **Live latency + bandwidth graph** that works in both sharing modes:
  the top strip is latency to the tracked device (teal filled line with
  avg/max, red bars = dropouts), the bottom strip is live hotspot
  throughput - **to devices** (amber area) and **from devices** (indigo
  line) in Mbps with session totals from the adapter counters
- **Pick the tracked device from the Track dropdown** (or right-click a
  device -> "Watch latency"); by default the graph follows the first
  connected client
- **Click a device to pin a static IP**: double-click a connected device
  (or right-click it, or use the "Pin static IP" button) and the
  reservation dialog comes up pre-filled with its name, MAC and a
  suggested free IP - no MAC typing, ever
- **System tray icon** (teal signal wave) with a right-click menu
  (open / start / stop / exit) and balloon notifications on start/stop -
  while the window itself minimizes normally to the taskbar (v2.4.0:
  it no longer hides into the collapsed tray, which looked like a crash)
- **Copy SSID+pass button** for the clipboard
- **Live log** with band/channel display
- **Redesigned dark UI**: flat cards, teal accents, status pill, responsive
  window (no freezing during start/stop, scrolls on small screens), and
  DPI-aware scaling - the layout renders correctly on 125-150% displays
  and labels sit above their fields, so text never overlaps the boxes
- No telemetry, no background services, nothing installed - close the
  window and everything is gone (settings are kept in two small files next
  to the scripts)

### How it works (and why it works when Windows can't)

The app brings up the access point through the **Wi-Fi Direct Autonomous
Group Owner** path (`WiFiDirectAdvertisementPublisher` + `LegacySettings`)
- the same mechanism commercial hotspot apps use on modern machines where
the legacy "hosted network" is gone. That path lives in `wlansvc`, not in
`icssvc`, so a damaged tethering settings store does not affect it. The
full detective story, with evidence, is in
[docs/THE-SAGA.md](docs/THE-SAGA.md).

### About 5 GHz

The Wi-Fi Direct legacy-AP API does not expose a band switch. The hotspot
channel **follows your uplink connection's channel** - connect the PC to a
5 GHz network and the hotspot runs 5 GHz too (driver-governed; the app
shows the live band/channel in the log at start).

### VR mode - what it trades away

While VR mode is active, Windows does not scan for networks, which means
it also **will not notice network changes**: if the uplink network drops
and comes back, Windows may not reconnect until the hotspot is stopped.
That is exactly the tradeoff rhythm gamers want (unbroken latency beats
auto-reconnect), but it is the first thing to turn off if your uplink is
flaky. The checkbox state is remembered between runs.

### Requirements

- Windows 10 or 11, any edition, with the built-in Windows PowerShell 5.1
- Administrator rights (the launcher requests them)
- A Wi-Fi adapter with Wi-Fi Direct support (virtually all modern laptops/
  USB dongles; if Windows' own hotspot ever worked on the machine, this
  will too)

### Files created at runtime (next to the scripts)

- `hotspot-settings.json` - your settings
- `reservations.csv` - static IP reservations
- `studio-crash.log` - written only if the app ever fails to start; it
  contains the exact error - keep it when reporting a problem (v2.4.0)
- `vrmode.flag` - crash-safety marker while VR mode has Wi-Fi scans paused
  (deleted automatically when scans resume; if the app ever crashes while
  running, the next launch cleans it up)

### Debug builds (ship alongside every release)

Every release from v2.9.0 on also ships **`vr-hotspot-kit-vX.X.X-debug.zip`**
on the same Releases page. It is the same app plus full instrumentation:
run it instead of the normal build whenever a problem needs reporting -
it records everything (a system survey at start, every log line with
millisecond timestamps, DHCP packet detail, per-query DNS lines, 30 s
state snapshots, the Windows WLAN event tail, crash records) to **one
file**, `debug-logs\vrhs-debug-<timestamp>.log` next to the script,
which you simply attach to your report. The hotspot password is never
written. Details: [debug/README-DEBUG.md](debug/README-DEBUG.md) (also
shipped inside the debug zip).

---

## Repository layout

```
VR-Hotspot-Studio.bat / .ps1    the hotspot app (run the .bat)
debug/                          the debug build (generated alongside every release)
Publish-to-GitHub.bat / .ps1    one-click repo publisher (maintainer use)
LICENSE                         MIT
docs/
  THE-SAGA.md                   full case history + root-cause analysis
  TROUBLESHOOTING.md            symptoms -> fixes for app and Windows stack
  PRINTER-STATIC-IP.md          giving a 3D printer a fixed address
  PUBLISHING.md                 how to publish/update this repo on GitHub
```

(The diagnostic/repair scripts built during the original troubleshooting
were removed from the repo in v1.0.2 - the hotspot app made them
unnecessary. They remain in the git history under `repair/` in older tags,
e.g. `v1.0.1`.)

## Troubleshooting

Start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The three
most common items:

- **"Publisher ABORTED"** - another hotspot app still holds the radio.
  Fully exit MyPublicWiFi / turn the Windows toggle off, try again.
- **Devices were kicked off after ~2 minutes / password asked again** -
  a real bug through v2.5.0. v2.6.0 had the right fix but it could
  never arm on Windows PowerShell 5.1 (the console showed "Windows
  PowerShell cannot subscribe to Windows RT events"); v2.7.0 moved the
  event subscription into compiled C# but still accepted each client
  through a queue and disposed the connection request too early;
  v2.8.0 runs the entire accept flow in C#, exactly like the official
  Microsoft Wi-Fi Direct sample. Details in the doc below.
- **Clients connect, no internet** - wrong uplink selected, or the
  SharedAccess service stopped; details in the doc.
- **The app will not start / PowerShell asks to "supply values"** -
  that was a real bug through v2.4.0, fixed in v2.5.0: a layout helper
  named `SC()` was silently shadowed by the built-in `sc` alias of
  `Set-Content` (in PowerShell, aliases outrank functions). If the app
  ever fails to start again, the launcher runs `-NonInteractive` and
  writes the exact error to `studio-crash.log` (a script that fails to
  even parse exits before a log can be written - the console shows
  that error instead).
- **A 2.4 GHz-only device can't see the hotspot** - you're on a 5 GHz
  uplink; the band follows the uplink (see above).

## Version history

- **v2.9.0-debug** - the first **debug build**, and a standing policy:
  every release from now on ships one alongside the normal zip. Same
  app, plus everything recorded to one submittable file - a system
  survey at start (OS, PowerShell, Wi-Fi driver, adapters, addresses,
  services, firewall, NAT, the last 12 h of WLAN-AutoConfig events),
  every log line persisted with millisecond timestamps, DHCP DISCOVER
  detail (requested IP, hostname, parameter list), per-query DNS lines
  (name, answering resolver, bytes, latency), a `[snap]` state snapshot
  every 30 s, new WLAN / system error events tailed every 60 s, and any
  crash copied into the debug log before the app exits. The hotspot
  password is never written. See "Debug builds" above.
- **v2.9.0** - the Router mode reliability pass. Field reports put
  almost every remaining problem in Router mode (Shared mode, where
  Windows owns the plumbing, was stable), and four real defects
  answered for it. The DHCP server's receive socket was bound to the
  hotspot's own unicast address, but a client's first DISCOVER is a
  **broadcast to 255.255.255.255:67, and Windows only guarantees
  delivery of those to wildcard-bound sockets** - so on some stacks the
  built-in DHCP never saw a knock at all: the device associated, never
  got an address, gave up and dropped off, which reads from the outside
  exactly like "kicked off, asks for the password again". The server
  now receives on a wildcard socket with a per-interface filter
  (`ReceiveMessageFrom`), replies through a second socket bound to the
  hotspot address (correct source IP, correct egress adapter, unicast
  renewals drained), retries binds instead of dying, and rebuilds a
  dead reply socket. The **ICS service (SharedAccess) is now stopped
  for the session** in Router mode: it hosts its own DHCP allocator on
  UDP 67 and re-applies remembered bindings to adapters, and on the
  stripped images this app targets the COM call that disables sharing
  is often missing - so the service fought the built-in DHCP
  mid-session (restored on stop, and the watchdog removes any foreign
  address that appears on the hotspot adapter). The DNS relay was
  rewritten as compiled C# with eight forwarding workers after a burst
  of lookups proved it serialized (15 queries once relayed: 1). And a
  `[router]` watchdog now checks all router-mode machinery every ~15 s
  and **repairs it within a budget** instead of advising a hotspot
  restart that would have dropped every connected client. STOP also
  reverts IP forwarding (it used to outlive the hotspot on the uplink)
  and restarts the ICS service if the app had stopped it. Test suite
  grown to 213 assertions, including live loopback tests that exercise
  the real DHCP source (DISCOVER/OFFER, renewal ACK, INIT-REBOOT NAK,
  RELEASE, reservations) and the compiled DNS relay (parallel burst
  forwarding, failure events, disarm).
- **v2.8.0** - the keep-alive done the way the official sample does it.
  v2.7.0 moved the Wi-Fi Direct `ConnectionRequested` subscription into
  compiled C# (PowerShell 5.1 cannot subscribe WinRT events), but it
  still handed each request to the GUI timer and - the fatal flaw -
  **disposed the `WiFiDirectConnectionRequest` before the accept ran**.
  The official Microsoft sample accepts inside the event handler and
  keeps the request object alive until `FromIdAsync` completes; a
  request released early can leave the association unaccepted, and
  Windows then drops that client about two minutes later, exactly the
  symptom v2.7.0 still showed. v2.8.0 keeps the entire flow in C#:
  the listener, the event handler, the immediate `FromIdAsync` accept
  (with one retry), a held-session table strong enough that nothing in
  PowerShell can release it by accident, and a
  `ConnectionStatusChanged` watch that frees sessions when the client
  actually leaves. Every step is logged (`[wfd]` lines: request seen,
  accepted, released, failures, stalls) plus a two-minute heartbeat
  with the held count - if a client is ever dropped again, the log
  names the exact stage that failed.
- **v2.7.0** - the v2.6.0 keep-alive, working for real this time.
  v2.6.0 subscribed the Wi-Fi Direct `ConnectionRequested` event with
  `Register-ObjectEvent` - but **Windows PowerShell 5.1 refuses to
  subscribe to Windows RT events**, and it does so with a
  *non-terminating* error: the app's try/catch never fired, the log
  said "keep-alive armed", and every client was still dropped after
  ~2 minutes (the giveaway was the "cannot subscribe to Windows RT
  events" errors in the console). v2.7.0 compiles a small C#
  bridge at runtime (`Add-Type`), which subscribes the event properly,
  queues each connection request and hands it to the GUI timer, where
  the accept logic runs on the UI thread as before. Same fix, mechanism
  that actually exists on PS 5.1. Also: **phantom devices with the
  all-zero MAC** (00:00:00:00:00:00) no longer appear in the device
  list - those rows are unanswered ARP probes (a VPN or tunnel such as
  Tailscale scanning the subnet from the host side creates them), and
  they used to show up as a fake device fighting over a real device's
  reserved IP address.
- **v2.6.0** - the "kicked off after a few minutes" fix, at the root. A
  Wi-Fi Direct access point must hold a `WiFiDirectDevice` session for
  every connected client; if nobody accepts the connection, Windows
  silently drops the client roughly two minutes after it associates -
  which is exactly what happened to printers and headsets (some clients
  then refused to rejoin until the password was retyped, and repeated
  drops looked like "no internet"). The app now runs a
  `WiFiDirectConnectionListener`, accepts every client and holds its
  session for as long as the hotspot runs; the count is visible in the
  status line and one `[wfd]` log line is written per client. Also:
  self-healing (the publisher is auto-restarted up to 3 times with the
  budget restoring after 5 stable minutes), system sleep is prevented
  while hosting, physical-adapter power saving is now disabled before
  the AP starts with a real adapter reset so it actually applies (the
  uplink may blip for a few seconds at start while the radio resets),
  Router
  mode gained a DNS relay (clients resolve through the hotspot PC;
  falls back to direct resolvers), NAT startup lists competing NAT
  instances (WSL / Docker / Hyper-V occupy the single NAT slot Windows
  provides), latency pings carry an explicit timeout (fewer false red
  dropout bars), and right-clicking a device offers **Test connection**
  (3 pings + TCP probes of ports 80/443/9100, logged) for printers
  whose web page will not load although ping works.
- **v2.5.0** - the real startup fix (found via the v2.4.0 crash log).
  v2.3.0's DPI rework had added a layout helper named `SC()`; in
  PowerShell **aliases outrank functions**, and `sc` is the built-in
  alias of `Set-Content` - so every layout call was really
  "Set-Content <number>" waiting for its mandatory `-Value` parameter.
  That single name collision produced the "Supply values for the
  following parameters" freeze on v2.3.0 and, under v2.4.0's
  `-NonInteractive`, the "missing mandatory parameters: Value" crash
  recorded in `studio-crash.log` before the window could open - the
  GUI had not successfully started once since v2.3.0 shipped. The
  helper is now `Scale-Px`, and the app deletes the dangerous built-in
  aliases at startup so no function it defines can ever be shadowed
  again. Everything v2.3.0/v2.4.0 shipped (custom subnet, bandwidth
  strip, Track dropdown, DPI-scaled layout, taskbar minimize) becomes
  visible for the first time.
  Also hardened after a two-agent review: the log view no longer yanks
  scrolled-up readers to the bottom every second (wheel/arrow scrolling
  suspends following; End or a click at the bottom resumes it),
  refusing the exit prompt no longer leaves a pending auto-close, a
  dead DHCP server in Router mode now warns on the status bar instead
  of silently leaving clients without addresses, the log trim is safe
  under concurrent writers, and the Track dropdown is never rebuilt
  while it is open.
- **v2.4.0** - startup robustness and two bug fixes: the launcher now
  runs PowerShell with `-NonInteractive` (no more freezing on a
  "Supply values for the following parameters" prompt, whatever its
  cause), checks admin rights with `fltmc` (no Server-service
  dependency, no elevation loop on stripped Windows images), keeps the
  console open after a failed launch, and writes any unhandled startup
  error to `studio-crash.log` with a message box; minimizing the window
  is a normal taskbar minimize now (it no longer hides into the tray
  and looks like the program closed); and the bandwidth strip was fixed
  - `Get-NetAdapterStatistics` has no `-InterfaceIndex` parameter, so
  the v2.3.0 sampling silently never worked on real Windows (counters
  are now matched by exact adapter name).
- **v2.3.0** - your-subnet Router mode (any private /24, uplink-collision
  guard, stale-address cleanup, per-subnet reservation filtering), the
  latency card gained a visible **Track** dropdown and a live **bandwidth
  strip** (to/from devices, Mbps + session totals), and the whole UI went
  DPI-aware with labels above fields (fixes text overlapping input boxes
  on 125-150% scaled displays). Validated by a 170-assertion suite
  (parse, units incl. IP-validation and byte formatting, real loopback
  DHCP incl. out-of-subnet reservation guards, simulated tracker
  lifecycle incl. bandwidth sampling, real GDI+ drawing of both graph
  zones, 10 s concurrency stress) plus a coordinate-level automated
  layout audit (no control overlaps at 100%, 115% text scale and 150%
  DPI). Hardened after a three-agent review (correctness 6->8, UX 7,
  PS 5.1/security 7.5) plus a verification round: the reservation
  subnet invariant is now enforced inside the DHCP server itself,
  bandwidth sampling addresses the hidden WFD adapter by interface
  index, Router mode fails fast (and cleans up VR mode) when the
  adapter address cannot be set, the uplink-collision check is
  prefix-aware, and IPs are canonicalized before use.
- **v2.2.0** - device tracker rework: no more blinking entries on connect,
  the list keeps updating with VR mode on, latency graph works in Router
  mode too and survives power-saving clients (1 s / 1 s timeout pings that
  double as keepalives), click-to-pin static reservations, "Watch latency"
  on any device, log no longer freezes after long sessions, start/stop no
  longer freezes the window, redesigned dark UI. Hardened after a
  three-agent code review: thread-safe snapshot reads everywhere,
  RFC-correct DHCP lease option byte order, 12 h lease expiry, sanitized
  client hostnames, firewall rule for the built-in DHCP server, ICS subnet
  auto-adoption, single-instance guard, non-ASCII adapter names safe in
  the VR-mode flag. Validated by a 108-assertion automated suite (parse,
  units, real loopback DHCP incl. hostile-hostname handling, simulated
  neighbor lifecycle, 10 s concurrency stress, real GDI+ drawing) plus
  PSScriptAnalyzer PS 5.1 syntax checking (zero findings).
- **v2.1.0** - fixed the v2.0.0 startup errors, static IP reservations
  (broken since v1), DHCP correctness, hotspot restart race.
- **v2.0.0** - VR mode, auto-start, tray icon, latency graph.
- **v1.x** - the original Wi-Fi Direct hotspot app.

## Why the repo exists

The kit was developed on a machine whose Windows 11 Mobile Hotspot broke
permanently after a tiny11 stripping accident (details:
[docs/THE-SAGA.md](docs/THE-SAGA.md)). Rather than re-bloat the OS to repair
one component, the fix became an app that doesn't need the component.

## Security note

Never paste account passwords into chat windows or AI tools. If one has
been shared anywhere, rotate it immediately (github.com -> Settings ->
Password). GitHub has not accepted passwords for git operations since
August 2021 - use a Personal Access Token, scope it to `repo`, delete it
when done. This repo contains no credentials by design; user-created files
(settings, reservations) are git-ignored.

## License

[MIT](LICENSE) - use it, fork it, no warranty.
