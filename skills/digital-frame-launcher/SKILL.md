---
name: digital-frame-launcher
description: Turn an Android digital photo frame (Frameo or similar) into a full-screen looping video player by installing the VideoLoop launcher over ADB, and later upgrade, verify or revert it. Finds the frame on the network or USB, checks compatibility (Android version, root, screen, memory-card/USB paths, Wi-Fi), checks its security (hidden root agents such as iotv, Android/firmware updates including those triggered from Frameo, hard-coded DNS, open ports) and helps neutralize what it finds, records and backs up the original state, builds and installs the app, makes it the home screen, loads a test video, verifies the endless loop, and can put the frame back on its original home screen exactly. Use this whenever the user wants to set up, onboard, convert, hack or "take over" a digital photo frame or similar small Android display, connect to a frame with adb, install or update VideoLoop, check whether a frame is safe or phoning home, remove iotv, turn off Android updates, bring a frame set up earlier (Frame1, Frame2, ...) up to date with the current checklist, or restore a frame's original launcher — even if they don't mention VideoLoop, ADB or launchers by name.
---

# Digital frame launcher (VideoLoop)

Take a frame from "unknown Android box on the network" to "boots straight into a
looping video", in a way the user can always undo. VideoLoop is a tiny launcher
(repo: github.com/tzvister/digital-frame-video-launcher) that plays one local video
forever, full screen, and has a hidden menu (two-finger press-and-hold ~1.5 s) for
choosing videos, importing from a memory card/USB stick, screen rotation, network
info and reverting.

Scripts live in this skill's `scripts/` folder; run them from the skill directory.
Each one that touches a frame takes `-s <serial>` (an `ip:5555` or USB serial).

## Ground rules, and why

- **Nothing changes on the frame until the user has seen the survey and said go.**
  Frames differ a lot; the user should know what will happen to theirs.
- **Check security before the frame goes to work.** Cheap frames ship with root,
  old patches and sometimes a hidden agent that phones home; the user should hear
  about it before VideoLoop (and their videos) go on, and before it joins their Wi-Fi.
- **Snapshot before any change.** Revert works by knowing what the original home
  screen was. `install_app.sh` refuses to run without a snapshot for that frame.
- **The user's media is theirs.** Never delete, overwrite or move videos or photos
  on the frame or a memory card without their explicit OK. The only file this skill
  adds is the test video; ask before replacing anything.
- **Ask before** installing software on the Mac (the build toolchain), rebooting the
  frame, uninstalling, or reverting.
- **Don't verify playback with screenshots** — on some frames `screencap` stalls the
  decoder. `verify.sh` reads VideoLoop's own log instead.
- **The user may be touching the frame while you work.** Don't send taps without
  saying so, and re-check state rather than assuming your action caused a change.
- Talk to the user in plain language (they may not know what "adb" or "root" means);
  explain a term the first time it matters.

## Before you start

Requirements, so you can set expectations early:
- **A Mac** (Apple Silicon or Intel) **with Homebrew**. `tools/setup-toolchain.sh` in
  the repo installs everything else (adb, JDK 17, Android SDK; ~1 GB, no sudo) — ask
  the user before running it. If Homebrew is missing, point them to https://brew.sh.
- **A frame that allows ADB**, over the network or a USB data cable, running Android
  4.4 or newer. Many frames don't allow ADB out of the box; if `find_frames.sh` finds
  nothing, that's the first thing to solve (references/adb-access.md). Root is optional.

On first run adb may trigger a macOS firewall prompt that must be allowed. The repo's
`devices/` folder holds helpers for one specific frame model; don't use them on others.

## New frame: the full flow

### 1. Find and connect
If the user can see the frame's IP (its Wi-Fi settings, the router's client list, or
VideoLoop's *Network info*), check just that host: `FRAME_NETS=<ip>/32
scripts/find_frames.sh`; for a frame on a USB cable only, `FRAME_NETS=none` skips the
network sweep. Otherwise `scripts/find_frames.sh` lists USB devices and
sweeps the Mac's local networks for adb on port 5555 (3 s per host, because frame
Wi-Fi dozes). The sweep asks every device there with adb open to identify itself,
which can pop an "Allow debugging?" prompt on, say, an Android TV, so mention that
before sweeping a shared network. Each line shows serial, model,
Android version, whether VideoLoop is installed, and the frame's name if it was set
up before. Frames' IPs often change on every boot, so go by name, not address. If
several devices appear, ask which one is the frame. If none appear, or one is `unauthorized`, read
**references/adb-access.md** and walk the user through it.

### 2. Survey and decide
`scripts/survey.sh -s <serial>` is read-only and prints `key=value` facts plus
`verdict=ok|warn|block` and `notes=`. Present it as a short report, for example:

```
Frame: <frame_name or "not named yet"> — <manufacturer model>, Android <android> (API <sdk>), <display>, root: <root>
Home screen now: <home_current>
Storage: <primary_storage> (<primary_free>); cards/USB: <removable_mounts or "none mounted">
Wi-Fi: <wifi_iface> <ip> (MAC <wifi_mac>)   Rotation sensor: <accelerometer>
Plan: make VideoLoop the home screen by <method — see below>; revert restores <home_current>.
Verdict: <ok/warn/block> — <notes in plain words>
```

How VideoLoop will take over (from **references/compatibility.md**): Android 7+ →
*preferred* (no root); older with root → *disable* the original home; older without
root → *chooser* (the user taps VideoLoop + Always once). If the verdict is `block`,
stop and explain. If VideoLoop is already installed, switch to **Bring an existing frame up to date** or
**Revert** below. Otherwise go on to the security check, and ask the user to
confirm both reports together before anything changes.

### 3. Security check
`scripts/security_scan.sh -s <serial>` is read-only and ends with
`security=clean|review|risk` and `notes=`. Add it to the report, for example:

```
Security: <clean/review/risk> — <notes in plain words>
Hidden agents: <agent_* states>   Android updates: <off, or updaters_enabled/running>
Root held by: <root_shells_held_by or "nothing">   Open ports: <listening or "none">
```

- `clean`: say so in one line and continue.
- `review`: explain each note and what you'd suggest (see **references/security.md**),
  then continue once the user is happy. Nothing here blocks VideoLoop.
- `risk` because **Android/firmware updates are on** (`updaters_enabled`,
  `updaters_running`, or an `update_staged` file): Frameo's own "Android update"
  screen and the vendor service can install firmware without asking, which can replace
  `/system`, undo this setup or bring back a removed agent. Explain that, and with the
  user's OK run `scripts/disable_updates.sh -s <serial>` (reversible with `--undo`;
  it waits until Android has saved the change, so a reboot can't lose it). If an
  update is staged, don't reboot until it's removed. `frameo_version` shows whether
  Frameo has updated itself (an app update, not Android); switching Frameo off
  entirely after the install stops that (see step 8).
- `risk` (a known hidden agent such as `iotv`, or a root process talking to the
  internet): **stop**. Recommend keeping the frame off the user's Wi-Fi, or on an
  isolated guest network, until it's dealt with. Then offer to neutralize it by
  following **references/security.md** step by step. That writes to `/system`, so
  it needs root and the user's OK. Snapshot first (step 4), offer a backup that
  includes `system` (step 5; the user's call), neutralize, rescan, and carry on from
  step 6. If the user declines the fix, record that in the hand-off and continue only
  if they say so.

If the frame was offline, `outbound` couldn't be checked. Once it's on Wi-Fi (an
isolated one if an agent was found), rerun the scan after step 10's reboot.

### 4. Snapshot the original state
`scripts/snapshot.sh -s <serial>` records the original home screen and the settings
we may touch, on the Mac (`<repo>/frames/<frame-id>/original.env`) and on the frame
(`<storage>/.videoloop/original.env`). It never overwrites an existing snapshot, and
refuses to record VideoLoop itself as "original". If it reports no default home
(a chooser), say so — revert will then simply step VideoLoop aside.

### 5. Back up (rooted frames, optional)
Backing up is the user's choice, not a gate: ask once, and skip it if they say no or
already have one (look in `frames/<frame-id>/`). Revert doesn't depend on it.
`scripts/backup.sh -s <serial>` pulls the boot-chain partitions and md5-checks each,
and skips itself cleanly without root. It's insurance against a bad flash; mention it
can take minutes on slow Wi-Fi, and keep it to the defaults (the `system` partition
takes hours over these frames' Wi-Fi). If step 3 found an agent to remove, say that a
backup with `--with-system` (over USB, about 1 GB, a few minutes) is the only way
back if a write to `/system` goes wrong, and let the user decide.

### 6. Network adb (before the install)
Decide this before the launcher goes on, so the reboot test in step 10 can run over
Wi-Fi and the frame stays manageable without a cable. If the survey shows
`adb_tcp_persist` empty, the frame stops answering adb over the network after its next
reboot. Ask the user: `scripts/network_adb.sh -s <serial>` turns adb on at port 5555
now and keeps it on after reboots (that part needs root; without root it lasts until
the next reboot). It lets them, and Claude, manage the frame over Wi-Fi later, but
leaves a debug port open on their network, root-capable on rooted frames. If the
security check found an agent, shows `adb_auth=off`, or the network is shared,
recommend against it, or an isolated network first. It prints
`network_adb_now`, `network_adb_after_reboot` and whether `adb connect <ip>:5555`
worked. Off again: `network_adb.sh --off`, or `revert.sh --restore-adb` as part of a
revert. If they decline, the step-10 reboot test can't be checked over the network;
use USB, or ask them to confirm the video came back.

### 7. Build the app
`scripts/get_app.sh` clones/updates the repo, builds, and prints the APK path. If it
says the toolchain is missing, ask the user, run `<repo>/tools/setup-toolchain.sh`,
then rerun.

### 8. Install and take over the home screen
`scripts/install_app.sh -s <serial> <apk>` installs, grants storage access, writes the
revert record on the frame first, then switches the home screen with the method above.
If it prints `ACTION NEEDED`, tell the user exactly what to tap on the frame.

If it stops because the installed VideoLoop **was signed with a different key** (built
on another Mac, or the key was lost), that's normal and harmless. Explain it, and with
the user's OK rerun with `--replace`: the frame briefly shows its original home screen,
the old app is removed, the new one installed and put back in charge, and the video
that was playing resumes. Videos, the frame's name and records stay; the rotation
setting resets.

**Name the frame.** People usually end up with several frames, and their IPs change,
so ask what to call this one (e.g. "Living room", "Kitchen"; suggest something if they
don't mind) and run `scripts/set_name.sh -s <serial> "<name>"`. The name shows in
VideoLoop's menu title and *Network info*, in `find_frames.sh`, and in the survey.
Rename any time by running it again.

**Switch the original app off (optional).** Once VideoLoop is the home screen,
Frameo (or whatever the original home app was) still wakes up in the background: at
boot, on network changes, from alarms and push messages. It then goes online, holds
root shells and updates itself (one frame pulled a `..._OTA_test` build). Offer
`scripts/original_app.sh -s <serial> --off`: it disables the whole package, only
while VideoLoop is the home screen, and waits until Android has saved it. Frameo's
photo sharing stops too, so it's the user's call. `--on` brings it back, and revert
(`revert.sh`, and the app's own menu from VideoLoop 2.5) turns it back on first.

### 9. Load the test video
`scripts/set_video.sh -s <serial> assets/test-video.mp4 --name loop.mp4` copies the
bundled 4-second 1280×800 test pattern into `<storage>/VideoLoop/` and tells VideoLoop
to play it. If the user wants their own video instead, use that path. If a different file of
the same name exists, the script stops — ask before using `--overwrite`.

### 10. Verify, reboot, verify again
`scripts/verify.sh -s <serial>` checks: VideoLoop is the home screen, in front, the
screen is on, and the video loops (≥ 2 play/loop events in 20 s; pass `--seconds` for
longer clips). Then, with the user's OK, `adb -s <serial> reboot`. After about a
minute, **find the frame again** — its IP may change on reboot — and run `verify.sh`
on the new serial. Booting straight into the loop is the real test.

### 11. Confirm the way back
`scripts/revert.sh -s <serial> --check` is read-only: it confirms the install record
exists on the frame, the original home app is still installed, and root is there if
the method needs it. Don't finish without an OK here — "can be reverted" is part of
the deliverable. Then run `scripts/checklist.sh -s <serial>`: every line should be OK
or INFO, and it records the frame as checked against the current checklist.

### 12. Hand off
Tell the user, briefly:
- The frame's name, and that it now boots into the looping video; which video is playing.
- Hidden menu: two-finger press-and-hold ~1.5 s → choose video, import from memory
  card/USB, screen rotation, network info (IP/MAC), Android settings (tap the floating
  *Back to VideoLoop* button to return), restore the original home screen, reboot.
- How to undo: ask Claude to revert the frame, or the menu's *Restore original home
  screen*. Where the records live (`frames/<frame-id>/` in the repo, and
  `.videoloop/` on the frame).
- Anything from the survey worth knowing (e.g. the IP changes on reboot; no rotation
  sensor; untested Android version).
- The security result: what was found, what was changed and where its undo notes
  are (`frames/<frame-id>/security-<date>/`), and anything still open (e.g. hard-coded
  DNS, so isolate it on the router; outbound not yet checked).

## Bring an existing frame up to date (checklist)
Frames set up by an older version of this skill miss whatever was added since (the
security check, updates off, network adb, a newer VideoLoop). `scripts/checklist.sh`
compares a frame with what the current skill does:

1. `scripts/checklist.sh --list` (no frame needed) shows every frame on record on this
   Mac, by name, with the checklist version it was last checked against: `never`,
   `vN BEHIND`, `vN k TODO` or `vN OK`. Tell the user which frames are behind.
2. Connect the frame (find it by name with `find_frames.sh`) and run
   `scripts/checklist.sh -s <serial> --verify`. Each line is OK, TODO with the command
   that fixes it, or INFO (the user's choice, e.g. network adb).
3. Present the TODOs in plain words and fix them with the user's OK, in step order:
   snapshot first if missing, then security (agents, `disable_updates.sh`), then
   network adb if they want it, then `get_app.sh` + `install_app.sh` for a newer
   VideoLoop. `install_app.sh` keeps the method from the first install, so revert still
   undoes the right thing; it needs `--replace`, with OK, if this Mac's signing key
   differs from the one that installed it.
4. Rerun `checklist.sh -s <serial> --verify` until there are no TODOs. That saves the
   result in `frames/<frame-id>/checklist.txt`, so `--list` shows the frame as current.

**Keeping the checklist current:** whenever this skill gains a step or a check, add an
item to `scripts/checklist.sh` and bump its `CHECKLIST_VERSION` (with a line in its
header saying what that version added). Older frames then show as BEHIND.

## Revert a frame
Confirm with the user first, and explain the options:
- default: the original home screen comes back; VideoLoop stays installed but inert.
- `--uninstall`: also remove VideoLoop.
- `--restore-adb`: put the network-adb setting back as it was originally. If it was
  off, the frame becomes unreachable over the network after the next reboot — say so.
- `--clean`: also remove VideoLoop's records (`.videoloop/`, including the frame's
  name). Videos in `VideoLoop/` are never touched; ask separately if the user wants
  them deleted.

Run `scripts/revert.sh -s <serial> [options]`, then (with OK) reboot, find the frame
again, and confirm with `survey.sh` that `home_current` is the original from the
snapshot.

## When something goes wrong
Read **references/troubleshooting.md** (stale/offline adb, dozing Wi-Fi, IP changes,
slow transfers, signature conflicts, a frame left without a home screen, simulating a
card insert). For version- or vendor-specific differences, **references/compatibility.md**.

## Files
- `scripts/` — `lib.sh` (shared), `find_frames.sh`, `survey.sh`, `security_scan.sh`, `snapshot.sh`,
  `backup.sh`, `disable_updates.sh`, `network_adb.sh`, `original_app.sh`, `checklist.sh`, `get_app.sh`, `install_app.sh`, `set_name.sh`, `set_video.sh`,
  `verify.sh`, `revert.sh`
- `assets/test-video.mp4` — 4 s generated test pattern (ffmpeg `testsrc2`), 1280×800,
  H.264 High, no audio
- `references/` — `adb-access.md`, `compatibility.md`, `security.md`, `troubleshooting.md`
