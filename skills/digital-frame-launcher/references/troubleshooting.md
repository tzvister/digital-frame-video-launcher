# Troubleshooting

Real problems hit while building and testing this on a frame, and what fixed them.

**adb says `offline`, or "No route to host", for a frame that was fine a minute ago.**
Stale network transport or dozing Wi-Fi. `adb disconnect <ip>:5555`, then connect
again (the scripts do this). Pings of up to ~1 s mean the frame's Wi-Fi is dozing or
the signal is weak — moving the frame (e.g. standing it in portrait somewhere else)
can do that. If it persists, ask the user to reboot the frame from VideoLoop's menu.

**Frame not found after a reboot.** Its IP probably changed (random MAC, see
compatibility.md). Rerun `find_frames.sh`; VideoLoop's menu → *Network info* shows the IP.

**adb hangs at "daemon not running; starting now".** macOS firewall prompt for adb
waiting behind a window — the user must click Allow.

**Transfers crawl (~0.1 MB/s).** Normal for these frames' Wi-Fi; it isn't the band.
Keep pushes small, skip raw backups of big partitions (`system` takes hours), and
don't pull user data unless asked.

**Taking screenshots to check playback.** Don't: `screencap` briefly stalls some
decoders, which trips VideoLoop's stall watchdog and makes it look broken. Use
`verify.sh` (it reads the app's log). If the user wants to see the screen, a single
screenshot is fine — just don't use it as evidence of looping.

**The video stops after one play.** Should not happen with VideoLoop ≥ 1.5 (watchdog).
If `verify.sh` shows 0–1 events, check the log for `no video to play` (storage
permission or path) and for MediaPlayer errors: `adb logcat -d | grep -iE 'VideoLoop|MediaPlayer'`.

**`install_app.sh`: INSTALL_FAILED_UPDATE_INCOMPATIBLE.** A VideoLoop signed with a
different key is installed. Uninstalling it removes the home screen it provides, so
first make sure another home is enabled (`revert.sh` does that), then uninstall and
install again. Keep `debug.keystore` in the repo so this doesn't happen.

**`set-home-activity` refused (Android 7+).** Some vendor builds block it. Fall back to
`--method chooser` (user taps VideoLoop + Always), or `--method disable` if rooted.

**After install, a chooser appears instead of VideoLoop.** A second launcher is
enabled besides the original. Let the user pick VideoLoop + Always; note it for revert.

**The frame ends up with no home screen.** Should be impossible via these scripts.
Recover with: `adb shell su -c 'pm enable <original_home>'` (from frames/<id>/original.env
or `<storage>/.videoloop/original.env` on the frame), or without root
`adb shell cmd package set-home-activity <original_home>` on Android 7+.

**Simulating a card/USB insert for testing.** `adb shell su -c 'sm list-volumes all'`
then `sm unmount <id>` / `sm mount <id>`. The ID format varies (`public:179,49` on most
builds, bare `179:49` on the astar-d7). VideoLoop offers the import ~1.5 s after mount.

**Hebrew/RTL file names look scrambled in dialogs.** Fixed in the app with
left-to-right marks; if new dialogs are added, wrap file names the same way.

**The user is touching the frame while you work.** They often are. Don't inject taps
without saying so; a tap of yours can land on a dialog they just opened. Before
concluding "my tap did X", check `adb logcat` for `injectMotionEvent` vs real touches.
