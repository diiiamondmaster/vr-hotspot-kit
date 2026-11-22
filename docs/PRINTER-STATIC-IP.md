# Giving the 3D printer a static IP on the hotspot

The printer needs a fixed address so slicing software can always find it.
There are two ways to get that with VR Hotspot Studio; use whichever matches
the sharing mode you run.

## Method A - Router mode reservation (recommended)

Router mode runs the app's own DHCP server, which supports **per-MAC static
IP reservations**.

1. Run `VR-Hotspot-Studio.bat` as Administrator.
2. Tick **Router mode (own DHCP + static IP reservations)**.
3. Start the hotspot and connect the printer to it once (it will get a
   dynamic address first - that is fine, we only need its MAC).
4. The printer appears in **Connected devices** with its MAC address.
   Copy the MAC.
5. In **Static IP reservations**, click **Add**, enter:
   - Device name: `Ender-3` (whatever you like)
   - MAC address: the one from the client list (any format works)
   - Static IP: e.g. `192.168.137.50`
6. Click **Save**, then stop and start the hotspot once. From now on the
   printer always gets `192.168.137.50`.

Reservations live in `reservations.csv` next to the app and survive restarts.

## Method B - Static config on the printer itself (works in Shared/ICS mode too)

Windows ICS has its own DHCP server with **no reservation feature**, so the
reservation has to be made on the printer instead:

1. On the printer's network settings screen (or its web UI), set:
   - IP address: `192.168.137.50` (anything from `.2` to `.254`;
     `.1` is the PC itself - avoid `.2`-`.10`, which ICS hands out first)
   - Subnet mask: `255.255.255.0`
   - Gateway: `192.168.137.1` (the PC, while the hotspot runs)
   - DNS: `1.1.1.1` and `8.8.8.8`
2. Save, reconnect the printer to the hotspot SSID, done.

Caveat: this address is only valid **on the hotspot network**. If the printer
also connects to a router sometimes, give it a different static address there
(or set it back to DHCP).

## Which IP range?

Both modes use `192.168.137.x`:

| Address | Meaning |
| --- | --- |
| `192.168.137.1` | the PC (gateway + DHCP server) |
| `192.168.137.2` - `.99` | ICS DHCP pool / general use |
| `192.168.137.100` - `.200` | Router-mode DHCP pool |
| `192.168.137.50` etc. | pick a fixed address outside the pool you use |

## Finding the printer's MAC

- Easiest: connect it once and read it from the app's **Connected devices**
  list.
- Or on the printer: network status / "About" page usually shows the Wi-Fi
  MAC.
- Or from an elevated PowerShell on the PC after it connects:
  `Get-NetNeighbor -InterfaceAlias "Local Area Connection* 12" | ft`
  (use the hotspot adapter's actual name from the app log).
