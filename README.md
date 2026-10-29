# Digital frame video launcher (VideoLoop)

A tiny Android launcher that turns a digital photo frame (built on a Frameo frame)
into a looping video player. It replaces the frame's home screen, plays one local
video full screen in an endless loop, and keeps a hidden admin menu for picking
videos, importing them from a memory card or USB stick, rotating the screen and
restoring the original home screen.

Built by hand with the Android SDK command-line tools (no Gradle, no libraries).
VideoLoop 2.0 runs on Android 4.4–15 (field-tested on Android 6). MIT licensed.

Not affiliated with or endorsed by Frameo; it was developed on a Frameo frame and
works with other Android frames too. Only modify devices you own.

## Set up a frame with Claude Code

The [`digital-frame-launcher` skill](skills/digital-frame-launcher/SKILL.md) takes any
frame from scratch: finds it on the network or USB, surveys compatibility, snapshots
the original state, backs it up, builds and installs VideoLoop, makes it the home
screen (the right way for that Android version and root situation), loads a test
video, verifies the loop across a reboot, and confirms it can be reverted. It also
upgrades and reverts frames. Install it by linking it into Claude's skills folder:

```bash
ln -s "$PWD/skills/digital-frame-launcher" ~/.claude/skills/digital-frame-launcher
```

Then ask Claude something like *"set up my photo frame to loop a video"*. It asks
what to call each frame ("Living room", ...): the name shows in VideoLoop's menu and
*Network info*, and the skill lists frames by name, which helps when you have several
and their IPs keep changing. Per-frame records (original state, name, backups) go to
`frames/<frame-id>/` (git-ignored) and to `.videoloop/` on the frame. The skill's scripts are the generic, any-frame versions
of the top-level `install.sh` / `revert.sh`, which remain for the original frame.

## The frame

| | |
|---|---|
| Board | Allwinner `astar-d7` (Frameo frame), 1280×800 panel |
| OS | Android 6.0.1 (`MOB30R`, `user/test-keys`) |
| Root | `/system/xbin/su`, grants root to `adb shell` without a prompt |
| Access | **Network ADB only** on port 5555. The USB port carried no data in testing (power only). |
| Wi-Fi | `rtl8189fs`. Picks a **new random MAC every boot**, so the DHCP IP changes each boot. Router reservations by MAC don't work. |
| Sensors | `mir3da` accelerometer (used for auto-rotation) |
| Video decoder | Allwinner CedarX. H.264 High, `yuv420p`, `.mp4` plays well. |

Frameo's own home screen is `net.frameo.frame/.ui.activities.AWaitForDeferredInitCompleted`
(also in [frameo_home.txt](frameo_home.txt)). VideoLoop takes over by *disabling*
that component, which is fully reversible.

## What the app does

- **Endless loop** of the chosen video, full screen, centred on black, screen kept on.
- **Hidden menu**: two-finger press-and-hold for ~1.5 s.
  - *Choose video…* lists videos in the frame's own storage (▶ marks the playing one).
  - *Import videos from memory card…* copies videos from a memory card or USB stick
    into `<storage>/VideoLoop/`. The same prompt appears automatically when one is
    mounted. Never writes to or deletes from the card. On a name clash it asks:
    **Overwrite**, **Keep both** (new name) or **Skip**.
  - *Screen rotation…* — **Auto** (default) follows how the frame is standing, so a
    portrait video fills the screen when the frame stands on its side. Also fixed
    landscape/portrait (and upside-down) for wall mounting.
  - *Network info* shows the current IP, MAC and the `adb connect` line.
  - *Open Android Settings* (Wi-Fi etc.), *Restore original home screen on next
    reboot*, *Switch to original home screen now*, *Reboot now*. Restoring uses the
    record the installer left in `<storage>/.videoloop/state`, and VideoLoop only
    steps aside once another home screen is confirmed to exist.
- Logs every play/loop under the `VideoLoop` tag (`adb logcat -s VideoLoop:I`).
- Wi-Fi is untouched; Android keeps managing saved networks.

## Layout

```
AndroidManifest.xml              app manifest (version, permissions, HOME alias)
src/videoloop/launcher/         the whole app (MainActivity.java)
build.sh                         compile + dex + sign -> VideoLoop.apk
install.sh                       install/upgrade on the frame and relaunch
revert.sh                        put the frame back on Frameo (works from the Mac, any time)
frameo_home.txt                  Frameo's home component, used by revert
debug.keystore                   (local only, git-ignored) signing key, see below
tools/setup-toolchain.sh         one-time Mac setup: JDK 17 + Android SDK 34
tools/find-frame.sh              find the frame's current IP on the LAN
tools/backup-firmware.sh         dd + md5-verify partitions over root adb
skills/digital-frame-launcher/   the Claude Code skill: scripts, references, test video
frames/                          (local only, git-ignored) per-frame records from the skill
backup/                          (local only, git-ignored) firmware images
```

**About `debug.keystore`.** It isn't in the repo: `build.sh` creates one on the first
build, so each person (or Mac) gets their own, and one key covers all of their frames.
Android only updates an installed app in place when the new build is signed with the
same key. If the key differs — another Mac, or a lost key — the skill's
`install_app.sh --replace` reinstalls instead: it hands the home screen back, swaps
the app, takes over again and resumes the playing video (only the rotation setting
resets). Keeping the key just saves that step.

## Build

```bash
tools/setup-toolchain.sh   # once
./build.sh                 # -> VideoLoop.apk
```

Bump `versionCode`/`versionName` in `AndroidManifest.xml` for each release.

## Update the app on the frame

```bash
./install.sh               # finds the frame on the LAN
./install.sh 192.168.1.50:5555     # or pass the address from the frame's Network info
```

`tools/find-frame.sh` first tries hosts the Mac already knows with the frame's
Wi-Fi vendor prefix (`00:e0:4c`), then sweeps the Mac's own networks for adb on
port 5555, and picks the device whose `ro.product.device` is `astar-d7`. It allows
~3 s per address because the frame's Wi-Fi dozes and can take a second to answer.
Override with `FRAME_DEVICE`, `FRAME_MAC_PREFIX` or `FRAME_NETS="192.168.1.0/24"`.
If the frame still isn't found, open *Network info* on the frame and pass that address.

## First-time setup on a fresh frame

```bash
D=<frame-ip>:5555
adb connect $D
adb -s $D shell "su -c 'setprop persist.adb.tcp.port 5555'"      # keep network adb after reboots
adb -s $D shell "mkdir -p /sdcard/.videoloop && echo '$(cat frameo_home.txt)' > /sdcard/.videoloop/frameo_home"
adb -s $D install -r VideoLoop.apk
adb -s $D shell "su -c 'pm disable $(cat frameo_home.txt)'"     # VideoLoop becomes the only home
adb -s $D shell input keyevent KEYCODE_HOME
```

Then add a video: insert a memory card with videos (the import prompt appears), or
`adb push` a file and pick it from *Choose video*. Until a video is chosen the app
plays `/sdcard/loop.mp4`, then the first video it finds.

Best video format for this panel: **1280×800, H.264 High, `yuv420p`, `.mp4`**.

## Revert to Frameo

```bash
./revert.sh                # or ./revert.sh <ip>:5555
```

Re-enables Frameo's home, disables VideoLoop's home role and reboots. VideoLoop
stays installed (`adb uninstall videoloop.launcher` to remove it). The in-app
*Revert* items do the same from the frame, but rely on `su` working for the app;
`revert.sh` is the dependable path.

## Remote test hooks

```bash
A=videoloop.launcher/.MainActivity
adb shell am start -n $A -a videoloop.launcher.SHOW_MENU
adb shell am start -n $A -a videoloop.launcher.SHOW_NETWORK
adb shell am start -n $A -a videoloop.launcher.SHOW_IMPORT
adb shell am start -n $A -a videoloop.launcher.SET_ROTATION --ei mode 2
adb shell am start -n $A -a videoloop.launcher.PLAY --es path /sdcard/VideoLoop/loop.mp4
adb shell am start -n $A -a videoloop.launcher.REVERT --es confirm yes   # same as the menu item
#   mode: 0 auto, 1 landscape, 2 portrait, 3 landscape upside down, 4 portrait upside down
```

Simulate re-inserting the memory card (fires the import prompt). This build uses the
bare `major:minor` volume id from `sm list-volumes all`:

```bash
adb shell "su -c 'sm unmount 179:49'"; adb shell "su -c 'sm mount 179:49'"
```

## Things learned the hard way

- **Looping.** CedarX ignores `MediaPlayer.setLooping` and fires `onCompletion` at
  most once per player. A watchdog (every 500 ms) restarts playback with a fresh
  data source at end-of-clip, on a ~2 s stall, or when a prepare hangs. It keeps
  running while menus and dialogs are open, so they never stop the video.
- **Don't verify playback with `screencap`.** Taking a screenshot briefly stalls the
  decoder and trips the stall restart. Count restarts in the log instead:
  `adb logcat | grep "mov open success"`.
- **Portrait videos** have no rotation flag to honour; they're simply stored tall.
  The fix is rotating the screen (accelerometer), never re-encoding the file.
- **RTL filenames.** Hebrew names scramble surrounding text in dialogs; labels are
  wrapped in left-to-right marks (U+200E).
- **Stale adb.** After a reboot or Wi-Fi drop, adb can keep an "offline" transport
  that makes every command fail; `find-frame.sh` disconnects and reconnects first.
- **ADB over this Wi-Fi is ~0.1 MB/s**, so a full `system` partition dump takes hours.

## Firmware backup

`tools/backup-firmware.sh [ip:5555] [out-dir] [partitions…]` pulls partitions as raw
images and md5-checks each against the frame. The default is the boot chain
(`bootloader env boot recovery misc private frp media_data`); add `system` if you
have hours to spare.

A verified boot-chain backup taken on 2026-10-29, before VideoLoop was installed,
is kept locally in `backup/frameo-backup-astar_d7-MOB30R/` and is deliberately not
in git. It does not include `system` or `/data`.
