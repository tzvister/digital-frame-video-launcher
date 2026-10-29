#!/bin/bash
# Record the frame's ORIGINAL state before VideoLoop changes anything, so revert can
# restore it exactly. Saved on the Mac (frames/<id>/original.env) and on the frame
# (<storage>/.videoloop/original.env). An existing snapshot is never overwritten.
#   scripts/snapshot.sh -s <serial>
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

ID="$(frame_id)"
DIR="$FRAMES_DIR/$ID"
OUT="$DIR/original.env"
P="$(primary)"
mkdir -p "$DIR"

if [ -f "$OUT" ]; then
  info "Original state already recorded for this frame (kept as-is): $OUT"
  cat "$OUT"; exit 0
fi

# A copy on the frame wins over a fresh look: the frame may already be modified.
on_frame="$(sh_ cat "$P/$DEVICE_DIR/original.env")"
if echo "$on_frame" | grep -q '^original_home='; then
  echo "$on_frame" > "$OUT"
  info "Recovered the original state from the frame's own copy: $OUT"
  cat "$OUT"; exit 0
fi

HOME_NOW="$(current_home)"
NOTE=""
if is_videoloop "$HOME_NOW"; then
  # Installed before snapshots existed (VideoLoop 1.x kept only Frameo's component).
  legacy="$(sh_ cat "$P/$DEVICE_DIR/frameo_home" | head -1)"
  if [ -n "$legacy" ] && ! echo "$legacy" | grep -qi 'no such'; then
    ORIG="$legacy"; NOTE="recovered from the VideoLoop 1.x record (frameo_home); original home was disabled"
  else
    die "VideoLoop is already the home screen and there is no record of the original one. Ask the user which app was the home screen before, then write it to $OUT as original_home=<pkg/.Activity>."
  fi
else
  case "$HOME_NOW" in
    *ResolverActivity*|"") ORIG=""; NOTE="no default home screen was set (Android showed a chooser)" ;;
    *) ORIG="$HOME_NOW" ;;
  esac
fi

{
  echo "# Original state of this frame, recorded before VideoLoop changed anything."
  echo "snapshot_time=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "frame_id=$ID"
  echo "serial_at_snapshot=$SERIAL"
  echo "model=$(prop ro.product.manufacturer) $(prop ro.product.model)"
  echo "fingerprint=$(prop ro.build.fingerprint)"
  echo "sdk=$(sdk)"
  echo "original_home=$ORIG"
  echo "original_home_candidates=$(home_candidates | tr '\n' ' ')"
  echo "adb_tcp_persist=$(prop persist.adb.tcp.port)"
  echo "adb_tcp_service=$(prop service.adb.tcp.port)"
  echo "accelerometer_rotation=$(sh_ settings get system accelerometer_rotation)"
  echo "note=$NOTE"
} > "$OUT"

sh_ "mkdir -p $P/$DEVICE_DIR" >/dev/null
a push "$OUT" "$P/$DEVICE_DIR/original.env" >/dev/null 2>&1 \
  || warn "couldn't copy the snapshot to the frame; the Mac copy is still valid"
info "Original state recorded: $OUT (copy on the frame: $P/$DEVICE_DIR/original.env)"
cat "$OUT"
