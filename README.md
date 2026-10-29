# Digital frame video launcher (VideoLoop)

A tiny Android launcher that turns a digital photo frame into a looping video
player. It replaces the frame's home screen, plays one local video full screen in an
endless loop, and keeps a hidden admin menu for picking videos, importing them from a
memory card or USB stick, rotating the screen and restoring the original home screen.

Built by hand with the Android SDK command-line tools (no Gradle, no libraries).
VideoLoop 2.1 runs on Android 4.4–15 (field-tested on Android 6). MIT licensed.

Not affiliated with or endorsed by Frameo; it was developed on a Frameo frame and
works with other Android frames too. Only modify devices you own.

## Requirements

- **A Mac** (Apple Silicon or Intel) **with [Homebrew](https://brew.sh)**. One script
  installs the rest: adb, JDK 17 and the Android SDK (~1 GB, no sudo).
- **A frame that allows ADB**, over Wi-Fi (port 5555) or a USB data cable, running
  Android 4.4 or newer. Many frames don't allow ADB out of the box; see
  [getting adb access](skills/digital-frame-launcher/references/adb-access.md).
  Root is optional.

## Set up a frame

The easy way is a coding agent. Clone this repo, open
[Claude Code](https://claude.com/claude-code) in the folder, and ask something like
*"set up my photo frame to loop a video"*. The
[`digital-frame-launcher` skill](skills/digital-frame-launcher/SKILL.md) loads
automatically (it's linked from `.claude/skills/`). It:

1. finds the frame on the network or USB,
2. surveys compatibility and shows you a plain-language report,
3. records the frame's original state (so it can be put back exactly),
4. backs up the boot partitions (rooted frames),
5. builds VideoLoop and makes it the home screen, the right way for that Android
   version and root situation,
6. asks what to call the frame (you'll likely have several, and their IPs change),
7. loads a test video, verifies the loop across a reboot, and confirms it can be reverted.

It stops for your OK before changing anything on the frame, installing software on
the Mac, rebooting, or reverting. It also upgrades and reverts frames later. Other
agents (Codex, Cursor, ...) are pointed to the same procedure by [AGENTS.md](AGENTS.md).
Without an agent, follow [SKILL.md](skills/digital-frame-launcher/SKILL.md) by hand;
every step is a script in `skills/digital-frame-launcher/scripts/`.

Per-frame records (original state, name, backups) go to `frames/<frame-id>/`
(git-ignored) and to `.videoloop/` on the frame.

## What the app does

- **Endless loop** of the chosen video, full screen, centred on black, screen kept on.
- **Hidden menu**: two-finger press-and-hold for ~1.5 s. Its title shows the frame's name.
  - *Choose video…* lists videos in the frame's own storage (▶ marks the playing one).
  - *Import videos from memory card…* copies videos from a memory card or USB stick
    into `<storage>/VideoLoop/`. The same prompt appears automatically when one is
    mounted. Never writes to or deletes from the card. On a name clash it asks:
    **Overwrite**, **Keep both** (new name) or **Skip**.
  - *Screen rotation…* — **Auto** (default) follows how the frame is standing, so a
    portrait video fills the screen when the frame stands on its side. Also fixed
    landscape/portrait (and upside-down) for wall mounting.
  - *Network info* shows the frame's name, IP, MAC and the `adb connect` line.
  - *Open Android Settings* (Wi-Fi etc.), *Restore original home screen on next
    reboot*, *Switch to original home screen now*, *Reboot now*. Restoring uses the
    record the installer left in `<storage>/.videoloop/state`, and VideoLoop only
    steps aside once another home screen is confirmed to exist.
- Logs every play/loop under the `VideoLoop` tag (`adb logcat -s VideoLoop:I`).
- Wi-Fi is untouched; Android keeps managing saved networks.

## Layout

```
AndroidManifest.xml              app manifest (version, permissions, HOME alias)
src/videoloop/launcher/          the whole app (MainActivity.java)
build.sh                         compile + dex + sign -> VideoLoop.apk
tools/setup-toolchain.sh         one-time Mac setup: adb, JDK 17, Android SDK 34
skills/digital-frame-launcher/   the setup / upgrade / revert procedure and its scripts
.claude/skills/                  link that makes Claude Code load the skill here
AGENTS.md, CLAUDE.md             orientation for coding agents
devices/astar-d7/                notes and helpers for the frame it was built on (that model only)
debug.keystore                   (local only, git-ignored) signing key, see below
frames/                          (local only, git-ignored) per-frame records
```

## Build

```bash
tools/setup-toolchain.sh   # once
./build.sh                 # -> VideoLoop.apk
```

Bump `versionCode`/`versionName` in `AndroidManifest.xml` for each release. Without
Homebrew, install JDK 17 and the Android SDK (build-tools 34, platform 34) yourself
and point the build at them with `VIDEOLOOP_JAVA_HOME=<jdk home>` and
`ANDROID_HOME=<sdk>`.

**About `debug.keystore`.** It isn't in the repo: `build.sh` creates one on the first
build, so each person (or Mac) gets their own, and one key covers all of their frames.
Android only updates an installed app in place when the new build is signed with the
same key. If the key differs (another Mac, or a lost key), the skill's
`install_app.sh --replace` reinstalls instead: it hands the home screen back, swaps
the app, takes over again and resumes the playing video (only the rotation setting
resets). Keeping the key just saves that step.

## Remote control hooks

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

## Things learned the hard way

- **Looping.** Some decoders (Allwinner CedarX) ignore `MediaPlayer.setLooping` and
  fire `onCompletion` at most once per player. A watchdog (every 500 ms) restarts
  playback with a fresh data source at end-of-clip, on a ~2 s stall, or when a
  prepare hangs. It keeps running while menus and dialogs are open.
- **Don't verify playback with `screencap`.** On some frames a screenshot briefly
  stalls the decoder and trips the stall restart. Read the app's log instead.
- **Portrait videos** usually have no rotation flag to honour; they're simply stored
  tall. The fix is rotating the screen (accelerometer), never re-encoding the file.
- **RTL filenames.** Hebrew names scramble surrounding text in dialogs; labels are
  wrapped in left-to-right marks (U+200E).
- **Cheap frame Wi-Fi.** Random MAC (so a new IP) every boot, dozing radios that take
  ~1 s to answer, stale "offline" adb links, and ~0.1 MB/s transfers. The scripts
  allow for all of it; frames are found by name, not address.

More frame-specific notes: [devices/astar-d7](devices/astar-d7/README.md).
