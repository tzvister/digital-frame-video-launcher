# Flyruit M10R5 (Frameo) — BLOCKED: ADB can't be authorized

**Status (2026-11-02): not solvable with VideoLoop from public tooling.** The frame
runs Frameo, ADB can be switched on, but the computer can never be *authorized*, so
the skill can't reach it. Use the **Frameo card route** below, or contact vendor
support. This page records what we tried so nobody repeats the dead ends.

Also sold as **Pastigio / SOMY M10R5**. 10.1", ~1280×800, Frameo.

## The frame

| | |
|---|---|
| SoC | Allwinner A33 family (`astar_xr819` per the wesbos device index), Android 6.0.1 |
| USB (SoC) | Enumerates as "Android", USB vendor `0x1f3a`, when ADB is on — but only ever `unauthorized` |
| USB (other) | A separate **Jieli Technology** composite device (audio/HID/storage) also appears. It is an internal chip, **not** the SoC — don't mistake it for the ADB/FEL interface |
| Network ADB | Port 5555 never opened; not reachable over Wi-Fi |

## Why it's blocked

Frameo exposes ADB at **Settings → About → Beta Program → ADB Access**. Turning it on
does start `adbd` (the frame appears in `adb devices`), but it stays **`unauthorized`**
and **never shows Android's "Allow USB debugging?" dialog** — that dialog is drawn by
**SystemUI, which is disabled on this build**, so there is no way to approve the
computer from the frame's screen. Without that one tap, every ADB command is refused.

This is exactly the M10R5 case in
[wesbos/photo-frame-dashboard issue #177](https://github.com/wesbos/photo-frame-dashboard/issues/177):
*"stays unauthorized with no prompt (SystemUI disabled)."*

Extra gotchas: ADB Access resets to **off after every reboot** (and the frame may stop
enumerating over USB entirely until you re-enable it).

## What we tried (all failed or dead-ended)

1. **Frameo's official ADB steps**, by the book: enable Beta Program + ADB Access,
   toggle off/on, replug the cable, `adb kill-server && adb start-server`, reboot and
   repeat. The frame stayed `unauthorized` through every cycle; the approval dialog
   never appeared. (Confirmed over many attempts.)

2. **FEL mode** (Allwinner's BootROM recovery). Built the host tools from
   [linux-sunxi/sunxi-tools](https://github.com/linux-sunxi/sunxi-tools) on macOS —
   deps: `libusb`, `dtc` (libfdt), `arm-none-eabi-gcc`, `u-boot-tools` (mkimage) — to
   get `sunxi-fel` plus an eGON `fel-sdboot.sunxi` stub. Wrote the 8 KB stub to a
   microSD at the sunxi boot offset (`dd if=fel-sdboot.sunxi of=/dev/rdiskN bs=1024
   seek=8`) and booted the frame from it.
   **Result: black screen, but the SoC never enumerated in FEL — no `1f3a:efe8` on
   USB, so `sunxi-fel` found nothing.** We could not get a FEL detection from any
   cable/port/power combination. This matches the *second* M10R5 owner in issue #177,
   whose frame also "went silent on USB." FEL entry itself is the wall here.

3. **Not pursued** — the only *documented working* M10R5 fix (issue #177) used a
   **custom, unpublished** key-writing tool plus an **offline edit of the userdata
   `adb_keys`** after a full eMMC backup. The author states it is "not a reusable
   recipe," and the tool isn't in the repo. The repo's A33 SD-card ADB route is
   **hash-locked to a different frame (PF1007L)** and refuses other firmware. So there
   is no public, reproducible path for this unit, and the comparable attempt failed.

## What works instead: Frameo "Play from external storage" (no ADB)

Gets your video on the screen today, without any of the above:

- **Card:** microSD, **≤32 GB**, **FAT32**.
- **Video:** `.mp4`, **≤720p (1280×720)** for this <1080p screen, **≤10 Mbps**.
- Put **only the one video** on the card. Insert it; Frameo pops a **Play** menu (that
  menu is also a useful "the frame reads the card and the screen works" signal).
  Tap Play. To get as close to a single-video loop as the stock app allows, also
  delete the frame's own photos in Frameo so the slideshow is just your clip.

It's a slideshow, not a VideoLoop kiosk (no boot-into-loop, no hidden menu), but it
needs no ADB and can't harm the frame.

## For the skill / future attempts

- **Detect this class early.** If `adb` shows the frame but `unauthorized`, Frameo's
  ADB Access is on, and no approval dialog appears, it's a **SystemUI-disabled Frameo
  build**. Don't loop on re-auth attempts — name it as the known hard case, offer the
  Frameo card route, and point the user at Frameo/Flyruit support.
- If anyone does revisit the FEL route: the make-or-break step is getting a clean
  `sunxi-fel version` response. Until that works, nothing downstream (backup, offline
  key insert) is reachable. That is where this unit stops.
