# Getting adb access to a frame

Read this when `scripts/find_frames.sh` finds nothing, or the frame shows up as
`unauthorized` / `offline`. Try the options in this order: each later one is more
work for the user and more frame-specific.

## 0. The Mac side

- Install adb: `brew install android-platform-tools`.
- The first time adb runs, macOS may pop up *"Do you want the application 'adb' to
  accept incoming network connections?"*. adb hangs at "starting daemon" until the
  user clicks **Allow** — tell them to look for that dialog (it can hide behind windows).
- The Mac and the frame must be on the same network. Guest Wi-Fi networks often
  isolate devices from each other, which looks exactly like "frame not found".

## 1. Network adb is already on (try first)

Many cheap frames ship with adbd listening on TCP 5555 (the Allwinner astar-d7
Frameo frame did, with no setup at all). `find_frames.sh` sweeps the Mac's networks
for it. If the user knows the frame's IP, `adb connect <ip>:5555` directly.

Where to find the frame's IP: the frame's own Wi-Fi/About screen, the router's
client list, or (once VideoLoop runs) its hidden menu → *Network info*.

## 2. USB

- Needs a **data** cable; many cables are charge-only. Many frames' USB ports are
  power-only or host-only (for USB sticks) — then USB adb is impossible.
- Check whether the Mac sees *any* device: `system_profiler SPUSBDataType` or
  `ioreg -p IOUSB -l -w0 | grep -E 'USB Product Name|idVendor'`. Allwinner devices
  often use vendor id `0x1f3a`; Google's adb id is `0x18d1`. Nothing new appearing
  when the cable is plugged in = no data connection.
- Once on USB, `adb tcpip 5555` switches the frame to network adb until the next
  reboot. Keeping it on across reboots needs root and the owner's OK
  (`install_app.sh --keep-network-adb`; see SKILL.md step 6 for the trade-off).

## 3. "Allow USB debugging?" (unauthorized)

adb lists the device as `unauthorized` until someone taps **Allow** on the frame's
screen. Ask the user to tap it (tick "Always allow from this computer").

## 4. Developer options on the frame

If the frame exposes Android Settings: *Settings → About → tap Build number 7 times*,
then *Developer options → USB debugging* (and *ADB over network* where offered).
Frame apps often hide Android Settings; don't guess vendor-specific secret gestures.

## 5. Vendor-specific routes

Per-device guides for common frames (Frameo, Dragon Touch, Pix-Star-like, Skylight,
etc.) are collected in https://github.com/wesbos/photo-frame-dashboard (device index):
how each one gets adb, root, and a launcher. Read the matching device's page rather
than improvising — some routes involve boot-image patching and should only be done
with the user's explicit go-ahead and a backup.

## Not useful

The recovery menu's *Apply update from ADB* is **sideload mode**: it only accepts a
signed update zip (`adb sideload`), with no shell. Don't use it to get access.
