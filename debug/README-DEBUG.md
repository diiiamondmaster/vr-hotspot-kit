# VR Hotspot Studio - DEBUG build (v2.9.0-debug)

This is the **same app as the normal v2.9.0 release** with one
difference: **it records everything** to a single log file that you can
submit with a problem report. Use it INSTEAD of the normal build
whenever something goes wrong and you want it diagnosed - a debug build
ships alongside every release from v2.9.0 on.

## How to use it

1. Extract this zip to its own folder (it will not disturb a normal
   install - the folder is named `vr-hotspot-kit-debug`).
2. Optional but recommended: copy `hotspot-settings.json` and
   `reservations.csv` from your normal VR Hotspot Studio folder into
   this folder, so the debug run uses your exact SSID, password and
   static-IP reservations.
3. Double-click **`VR-Hotspot-Studio.bat`** (Administrator, as usual).
4. Use the hotspot normally until the problem happens - client
   dropped, "connected, no internet", crash, whatever you are
   reporting.
5. Close the app (or let it crash). The log is at:

   **`debug-logs\vrhs-debug-<date>-<time>.log`**

   next to the .bat. The app also prints the full path in its own log
   at startup and at exit, and the launcher window mentions the folder
   when it closes.
6. Submit that ONE file with your report (attach it to the GitHub
   issue or discussion). If the app crashed hard, also attach
   `studio-crash.log` from the same folder.

## What it records

- **A system survey at startup**: Windows build, PowerShell version,
  elevation, power state (AC/battery), `netsh wlan show interfaces`
  and `show drivers` (band, channel, driver version, Wi-Fi Direct
  support), `ipconfig /all`, every adapter - hidden ones included -
  with its IPv4 addresses, the state of the Wi-Fi / ICS / firewall
  services, NAT instances, the app's firewall rules, and the last 12
  hours of **WLAN-AutoConfig events** - Windows' own record of every
  association and disassociation, with reason codes - plus recent
  System-log errors.
- **Every log line the app writes**, with millisecond timestamps and
  session uptime, including the Wi-Fi Direct keep-alive (`[wfd]`),
  DHCP (`[dhcp]`), DNS (`[dns]`) and Router watchdog (`[router]`)
  lines that the normal build shows in its own log window.
- **Extra detail the normal build does not log**: each DHCP DISCOVER
  with the client's requested IP, hostname and parameter-request
  list; each DNS query with its name, the resolver that answered,
  reply size and latency; a `[snap]` state snapshot every 30 s
  (clients, leases, held sessions, NAT, forwarding, ICS status,
  bandwidth totals); the router watchdog's check result even when
  everything is healthy; and new WLAN / system error events tailed
  every 60 s while the hotspot runs.
- **Crashes**: any unhandled error is copied into the debug log (with
  the log lines collected up to that point) before the app exits.

## Privacy

The log contains: your SSID, your uplink and adapter names, client MAC
addresses, IPs and DHCP hostnames, and the DNS **names** clients look
up. Your hotspot **password is never written** - the settings section
records it as `<redacted>`. If any of that still bothers you, open the
.log in Notepad and delete lines before submitting; the diagnostics do
not depend on any single line.

## Notes

- The debug log rolls over at 16 MB (a `.1` file appears next to it),
  and only the six newest logs are kept - the folder cleans itself.
- Everything the instrumentation does is wrapped in fail-safes: a
  logging problem cannot take the hotspot down.
- Behavior, features and fixes are identical to v2.9.0 - see the main
  README for what that includes.
