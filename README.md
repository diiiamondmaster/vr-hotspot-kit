# VR Hotspot Kit

A standalone Wi-Fi hotspot app for Windows that **does not depend on the
Windows Mobile Hotspot stack at all** - plus the complete diagnostic and
repair toolkit that was built while tracking down why that stack broke on a
debloated ("tiny11") Windows 11 machine.

If Windows says *"We can't set up mobile hotspot"*, the toggle flips itself
back off, or `GetTetheringCapability` throws `0x83120006` / "Element not
found" - this kit is for you. The headline app sidesteps all of it.

---

## Quick start (60 seconds)

1. **Download**: grab **`vr-hotspot-kit.zip`** from the **Releases**
   section (bottom of the right sidebar, or the "Releases" tag under the
   file list) - just the runnable files, no git needed. Prefer the whole
   codebase instead? Green **`<> Code`** button -> **Download ZIP**.
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
  [docs/PRINTER-STATIC-IP.md](docs/PRINTER-STATIC-IP.md))
- **Connected-clients list** (name / IP / MAC, names from your reservations)
- **Live log** with band/channel display
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

### Requirements

- Windows 10 or 11, any edition, with the built-in Windows PowerShell 5.1
- Administrator rights (the launcher requests them)
- A Wi-Fi adapter with Wi-Fi Direct support (virtually all modern laptops/
  USB dongles; if Windows' own hotspot ever worked on the machine, this
  will too)

---

## Repository layout

```
VR-Hotspot-Studio.bat / .ps1    the hotspot app (run the .bat)
Publish-to-GitHub.bat / .ps1    one-click repo publisher (maintainer use)
LICENSE                         MIT
docs/
  THE-SAGA.md                   full case history + root-cause analysis
  TROUBLESHOOTING.md            symptoms -> fixes for app and Windows stack
  PRINTER-STATIC-IP.md          giving a 3D printer a fixed address
  PUBLISHING.md                 how to publish/update this repo on GitHub
repair/                         diagnostic + repair scripts (the saga's tools)
```

## The repair kit (`repair/`)

Each script attacks one layer of the Windows Mobile Hotspot stack. They were
built during the diagnosis, in the order that made sense to rule things out,
and are kept because each is independently useful on any machine.

| Script | What it does |
| --- | --- |
| `Hotspot-Doctor` | full diagnosis report (services, radios, BT tree, NCSI, drivers) - writes `HotspotReport.txt` |
| `Hotspot-Capability-Check` | asks Windows for the official tethering verdict (`GetTetheringCapability`) - the fastest way to see the real error |
| `VPN-Hotspot-Test` | tests whether a VPN (Tailscale etc.) is the culprit |
| `Hotspot-5GHz-Setup` | configures the *Windows* hotspot to 5 GHz via the tethering API (needs a working tethering stack) |
| `Driver-Rollback` | lists all stored Wi-Fi drivers, rolls back, re-tests |
| `Restore-MobileHotspot` | deep repair of the icssvc service chain + registry fixes + legacy fallback |
| `Hotspot-BootFix` | for hotspots that die on reboot; installs an at-logon fix task |
| `Hotspot-DeepClean` | removes ghost Wi-Fi Direct adapters + stale ICS bindings |
| `Hotspot-Store-Reset` | backs up and resets the icssvc settings store (with .reg backup) |
| `Hotspot-Surgical-Repair` | DISM component-store repair from a mounted ISO - no setup.exe, no re-bloat, keeps apps/data |

All of them are `.bat`/`.ps1` pairs: double-click the `.bat`, accept the
Administrator prompt. Windows PowerShell 5.1 only; nothing to install.

## Troubleshooting

Start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The three
most common items:

- **"Publisher ABORTED"** - another hotspot app still holds the radio.
  Fully exit MyPublicWiFi / turn the Windows toggle off, try again.
- **Clients connect, no internet** - wrong uplink selected, or the
  SharedAccess service stopped; details in the doc.
- **A 2.4 GHz-only device can't see the hotspot** - you're on a 5 GHz
  uplink; the band follows the uplink (see above).

## Why the repo exists

The kit was developed on a machine whose Windows 11 Mobile Hotspot broke
permanently after a tiny11 stripping accident (details:
[docs/THE-SAGA.md](docs/THE-SAGA.md)). Rather than re-bloat the OS to repair
one component, the fix became an app that doesn't need the component. The
diagnostic scripts stayed because the reasoning trail is half the value.

## Security note

Never paste account passwords into chat windows or AI tools. If one has
been shared anywhere, rotate it immediately (github.com -> Settings ->
Password). GitHub has not accepted passwords for git operations since
August 2021 - use a Personal Access Token, scope it to `repo`, delete it
when done. This repo contains no credentials by design; user-created files
(settings, reservations) are git-ignored.

## License

[MIT](LICENSE) - use it, fork it, no warranty.
