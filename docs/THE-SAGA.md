# The Saga: how a tiny11 install broke the Windows Mobile Hotspot,
# and how it was diagnosed

This document is the full case history behind this kit. It is kept in the repo
because (a) it documents a genuinely interesting Windows failure mode, and
(b) anyone hitting the same wall can compare notes instead of redoing three
days of debugging.

## The machine

| Component | Detail |
| --- | --- |
| OS | Windows 11 build 26300 (26H2), edition Core, tiny11-based (debloated) |
| Wi-Fi/BT | Realtek RTL8822CE combo chip, driver 2024.10.138.3 (2024, user-installed) |
| Uplink | `ALPCC_Public`, 5 GHz channel 161 @ 866.7 Mbps link (25 Mbps internet) |
| Legacy hosted network | `Hosted network supported: No` (driver-level, not fixable in software) |
| Other damage | `BthAvctpSvc` missing (BT audio dead), Windows Update Settings page missing |

The owner deliberately runs a stripped image and was not willing to do an
in-place repair upgrade that would re-bloat the machine - which is exactly why
the final solution is an app that sidesteps the broken component entirely
instead of repairing it.

## Timeline

1. **Hotspot worked** for a long time (Windows Settings > Mobile Hotspot).
2. An **AI-generated boot auto-start script** was set up to turn the hotspot
   on automatically at logon.
3. After one restart, the hotspot **never worked again**: the Settings page
   showed the toggle flip on and off, and every start attempt failed.
4. The auto-start script was **completely removed** - the hotspot stayed broken.
5. MyPublicWiFi was installed as a workaround - and it **worked**. That single
   fact became the most important clue in the whole investigation: whatever
   was broken, it was not the driver, the radio, or the Wi-Fi Direct stack.
6. Diagnosis campaign (the scripts in this repo) ran layer by layer until the
   broken component was isolated.

## What was ruled out, in order

1. **Services** - `icssvc`, `SharedAccess`, `WlanSvc`, `Wcmsvc`, `NlaSvc`,
   `BFE`, `MpsSvc`, `RmSvc`, `bthserv` all present, running, correct start
   types. (Checked by `Hotspot-Doctor`, `Restore-MobileHotspot`.)
2. **Radios** - Wi-Fi and Bluetooth both `On` via `Windows.Devices.Radios`.
3. **NCSI/NLA** - internet detection working; the connection profile existed.
4. **Group policy / registry policy** - `NC_ShowSharedAccessUI = 1`, clean.
5. **VPN interference** - Tailscale tested on and off; not the cause
   (`VPN-Hotspot-Test`).
6. **Driver version** - hotspot had worked *before* the 2024 driver was
   installed; rolling back and forward changed nothing (`Driver-Rollback`).
7. **Ghost state** - ghost Wi-Fi Direct adapters and stale ICS bindings
   cleaned with `Hotspot-DeepClean`; the settings store was backed up and
   reset with `Hotspot-Store-Reset`. No fix.
8. **Tethering capability** - `GetTetheringCapability` **throws** on every
   connection profile (Wi-Fi, Ethernet, Tailscale, BT PAN):

   > `Element not found. Error reading stored data for this
   > MobileBroadbandAccount object.`

   `GetCurrentAccessPointConfiguration` fails with `0x83120006`, and
   `StartTetheringAsync` returns `Unknown`.

## Root cause

The **icssvc tethering settings-store code path is damaged at the component
level** (tiny11 stripped something the tethering service depends on):

- `HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings` exists but is
  **empty** - it can be written to but the service never reads it back.
- Every API that reads stored tethering configuration fails with
  "Element not found" - regardless of which network profile is used, which
  proves it is the *store reader*, not any particular profile.
- This is why the Settings UI cannot turn the hotspot on: the UI calls the
  same broken store.

MyPublicWiFi works because it never touches icssvc's tethering store. It
brings up the access point through **wlansvc / Wi-Fi Direct**
(`WiFiDirectAdvertisementPublisher` with `IsAutonomousGroupOwnerEnabled` and
`LegacySettings`) and wires internet sharing itself through ICS
(`HNetCfg.HNetShare`). That entire path is intact on this machine.

## The fix strategy

- **Primary:** `VR-Hotspot-Studio` (this repo's headline app) replicates the
  exact mechanism MyPublicWiFi uses - Wi-Fi Direct autonomous group owner
  with custom SSID/WPA2 passphrase, plus ICS or its own NAT+DHCP - with a
  GUI, a client list, and static-IP reservations. No broken components
  involved. This works **right now**.
- **Optional repair of the original feature:** `Hotspot-Surgical-Repair`
  mounts a matching official Windows 11 ISO and runs
  `DISM /RestoreHealth /Source=wim:...` to repair only the damaged
  component store - no `setup.exe`, no re-bloat, keeps apps/data/settings.
  Reboot, then verify with `Hotspot-Capability-Check` /
  `Hotspot-Store-Reset`.

## Hardware constraints worth remembering

- **One radio, one hotspot.** The Realtek 8822CE has a single Wi-Fi radio.
  Windows Mobile Hotspot, MyPublicWiFi and VR Hotspot Studio all want the
  same "AP role" on that radio - only one can hold it at a time. Stop one
  before starting another.
- **Band follows the uplink.** The Wi-Fi Direct legacy-AP API does not expose
  a band selector; the AP channel follows the operating channel of the
  uplink connection (currently 5 GHz ch161, so the AP is 5 GHz too). This is
  driver-governed behavior, not an API limitation an app can override.
- **Uplink and AP time-share the radio**, so real-world throughput tops out
  around 300-450 Mbps - plenty for Virtual Desktop / ALVR PCVR streaming,
  and far above the 25 Mbps internet uplink.
- The RTL8822CE reports `Hosted network supported: No`, so the old
  `netsh wlan start hostednetwork` path is dead on this hardware - which is
  fine, because Wi-Fi Direct replaces it.
