# Allwinner astar-d7 Frameo frame

The frame VideoLoop was developed and field-tested on. The helpers in this folder are
for **this model only**; for any other frame use the
[digital-frame-launcher skill](../../skills/digital-frame-launcher/SKILL.md).

| | |
|---|---|
| Board | Allwinner `astar-d7` (`sun8i`), sold as a Frameo frame, 1280×800 panel |
| OS | Android 6.0.1 (`MOB30R`, `user/test-keys`) |
| Root | `/system/xbin/su`, grants root to `adb shell` (and apps) without a prompt |
| Access | Network ADB on port 5555 out of the box. The USB port carried no data in testing. |
| Wi-Fi | `rtl8189fs`. Picks a **new random MAC every boot** (keeping the `00:e0:4c` prefix), so the DHCP IP changes each boot and router reservations by MAC don't work. |
| Sensors | `mir3da` accelerometer (used for auto-rotation) |
| Video decoder | Allwinner CedarX. H.264 High, `yuv420p`, `.mp4` plays well. |
| Original home | Frameo: `net.frameo.frame/.ui.activities.AWaitForDeferredInitCompleted` |

The skill took this frame over with the *disable* method (Android 6 + root): Frameo's
home component is disabled, and revert re-enables it.

## Helpers

```bash
devices/astar-d7/find-frame.sh                 # print the frame's current ip:5555
devices/astar-d7/install.sh [ip:5555] [--replace]   # update VideoLoop (build first)
devices/astar-d7/revert.sh  [ip:5555] [--check]     # back to Frameo (no reboot)
```

`find-frame.sh` first tries hosts the Mac already knows with the `00:e0:4c` Wi-Fi
prefix, then the skill's full network sweep, and picks the device whose
`ro.product.device` is `astar-d7` (override with `FRAME_DEVICE`, `FRAME_MAC_PREFIX`,
`FRAME_NETS`). `install.sh` and `revert.sh` are thin wrappers over the skill's
`install_app.sh` and `revert.sh`.

## Notes from this frame

- CedarX ignores `MediaPlayer.setLooping` and reports short clips as non-seekable;
  VideoLoop's watchdog restarts playback instead (logged as `play <path>`).
- `screencap` briefly stalls the decoder, so don't use screenshots to check looping.
- `sm list-volumes all` names the memory card `179:49` (not `public:179,49`):
  `su -c "sm unmount 179:49"` then `sm mount 179:49` simulates re-inserting it.
- ADB over its Wi-Fi manages ~0.1 MB/s regardless of band: a full `system` partition
  dump takes hours. The Wi-Fi also dozes (pings up to ~1 s), which the scripts allow for.
- After a few hours of heavy adb use its adbd once hung (TCP open, no handshake);
  unplugging the frame for 10 s fixed it. A menu reboot did not take.
