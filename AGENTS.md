# Notes for coding agents

This repo turns an Android digital photo frame into a looping video player:
**VideoLoop**, a small Android launcher app, plus a step-by-step procedure for
installing, verifying and reverting it on a frame over ADB.

## The user wants to set up, update, check or revert a frame

Follow **[skills/digital-frame-launcher/SKILL.md](skills/digital-frame-launcher/SKILL.md)**.
It is the procedure; its scripts are in `skills/digital-frame-launcher/scripts/`
(run them from that folder). Claude Code loads it automatically as the
`digital-frame-launcher` skill when opened in this repo (via `.claude/skills/`).

Read it fully before running anything. It says when to stop and ask the user:
before changing anything on the frame, before installing software on this machine,
before rebooting, reverting or uninstalling. The frame's original state must be
snapshotted (`scripts/snapshot.sh`) before any change, or revert can't restore it.

Requirements: macOS (Apple Silicon or Intel) with Homebrew, and a frame that allows
ADB over the network or a USB data cable. Many frames don't out of the box — see
`skills/digital-frame-launcher/references/adb-access.md` before going further.

Don't:
- run anything in `devices/` on other frames: those helpers are for one frame model.
- take screenshots to check playback (it stalls some decoders); use `scripts/verify.sh`.
- delete, overwrite or move the user's videos or photos on a frame or memory card
  without their explicit OK.

## The user wants to change the app

- The whole app is `src/videoloop/launcher/MainActivity.java` plus `AndroidManifest.xml`
  (no Gradle). Build with `./build.sh`; first-time toolchain: `tools/setup-toolchain.sh`.
- Bump `versionCode` and `versionName` in `AndroidManifest.xml` for every change you
  install, and check it on a frame with the skill's `scripts/install_app.sh` and
  `scripts/verify.sh`.
- `debug.keystore` is created on the first build and is git-ignored. If it differs
  from the key that installed the app on a frame, use `install_app.sh --replace`.
