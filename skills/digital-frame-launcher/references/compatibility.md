# What changes between frames

Read this when the survey shows an Android version, root type or storage layout
you haven't handled before, or a step fails in a version-specific way.

VideoLoop is plain Java (no native code), `minSdk 19`, `targetSdk 28`: one APK runs
on any CPU from Android 4.4 to 15. Field-tested on Android 6.0.1 (Allwinner
astar-d7 Frameo frame); other versions are supported by design but untested —
say so in the survey report, and lean on `verify.sh` results rather than assumptions.

## By Android version

| Android (API) | Home-screen method | Things to know |
|---|---|---|
| 4.4 (19) | `disable` with root, else `chooser` | No `cmd`. Primary storage may be `/mnt/sdcard` or `/storage/emulated/legacy`. Cards/USB often at `/mnt/extsd`, `/mnt/usbhost1`, `/storage/extSdCard`, `/storage/usbdisk`. `md5sum` may be missing (scripts fall back to sizes). |
| 5.x (21–22) | same | `sm` not available yet. |
| 6 (23) | same | Runtime permissions: `install_app.sh` grants storage with `pm grant`. Cards at `/storage/XXXX-XXXX` (FUSE view of `/mnt/media_rw/XXXX-XXXX`). `sm list-volumes all` works but some builds name volumes `179:49` instead of `public:179,49`. |
| 7–9 (24–28) | `preferred` (`cmd package set-home-activity`) | `cmd package resolve-activity` / `query-activities` give the home screen and candidates. No root needed to install or revert. |
| 10 (29) | `preferred` | Scoped storage doesn't apply: VideoLoop targets 28, so it keeps normal file access. |
| 11–13 (30–33) | `preferred` | Same; `requestLegacyExternalStorage` is set. |
| 14 (34) | `preferred` | Refuses apps targeting < 23 — VideoLoop targets 28, fine. |
| 15 (35) | `preferred` | Refuses apps targeting < 24 — fine. A future minimum above 28 would need the app's targetSdk raised (and real scoped-storage work). |

## Root comes in different shapes

- **toolbox/legacy `su`** (common on cheap Allwinner/Rockchip frames): `su -c id`
  works from adb shell with no prompt. `lib.sh` reports `root=su`.
- **Magisk `su`**: the first `su` from adb shell pops a *Grant* prompt on the
  frame's screen — ask the user to tap Grant, then rerun.
- **adbd as root** (userdebug builds, emulators): `adb shell id` already shows
  uid 0 (`root=adbd`). On a userdebug build `adb root` may switch it on; that
  restarts adbd, so reconnect afterwards. Don't run it on a frame without telling the user.
- **none**: everything still works except the `disable` method and raw backups.

## Home-screen methods (what revert undoes)

- `preferred`: VideoLoop is set as the default home; the original stays enabled.
  Revert: `set-home-activity <original>` + VideoLoop's home alias turned off.
- `disable`: the original home component is disabled with root, so VideoLoop is the
  only home and Android never shows a chooser. Revert re-enables it (needs root).
  Caveat: if the frame has a *second* launcher too (e.g. Launcher3 + the vendor app),
  disabling only the original leaves a chooser — the user then taps VideoLoop + Always.
- `chooser`: nothing disabled; the user picked VideoLoop + Always once.
  Revert: VideoLoop turns its own home alias off (no root needed — the app does it
  via the `REVERT` intent), and the original is the only home left.

In every case VideoLoop only steps aside after confirming another home screen is
enabled, so a revert can never leave the frame with none.

## Video decoders

Some decoders (Allwinner CedarX) ignore `MediaPlayer.setLooping` and fire
`onCompletion` once; VideoLoop's watchdog restarts playback itself and logs
`play <path>` each time. Decoders that do honour looping log `loop (native)`.
`verify.sh` counts both. Safest test video: H.264 (High/Main), `yuv420p`, `.mp4`,
ideally at the panel's resolution (from the survey's `display=`).

## Wi-Fi

Cheap Realtek chips (e.g. `rtl8189fs`) may pick a new random MAC every boot, so the
DHCP IP changes each boot and a router reservation by MAC won't work. After any
reboot, find the frame again (`find_frames.sh`) instead of assuming its old IP.
