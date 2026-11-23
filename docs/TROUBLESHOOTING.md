# Troubleshooting

> Note: the diagnostic/repair scripts mentioned below (Capability Check,
> Surgical Repair, etc.) were removed from the repo in v1.0.2 now that the
> app makes them unnecessary. They live in the git history under `repair/`
> in older tags (e.g. `v1.0.1`) if ever needed.

## The app

### The app will not start / a console asks to "supply values for the following parameters"
Older builds could end up frozen on that PowerShell prompt with the
window never appearing. Since v2.4.0 the launcher runs PowerShell with
`-NonInteractive`, so a prompting command fails immediately with a
visible error instead of hanging - and any unhandled startup error is
written to `studio-crash.log` (next to the script, or `%TEMP%`
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
- If the PC itself lost internet while the hotspot runs, the uplink adapter
  dropped - reconnect it and stop/start the hotspot so ICS re-binds.

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
accordingly.

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
