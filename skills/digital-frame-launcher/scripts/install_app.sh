#!/bin/bash
# Install (or upgrade) VideoLoop and make it the frame's home screen, recording how,
# so that revert.sh and the app's own menu can undo exactly that.
#   scripts/install_app.sh -s <serial> <VideoLoop.apk> [--method preferred|disable|chooser]
#                          [--replace] [--keep-network-adb]
#
# --keep-network-adb: make network adb survive reboots (persist.adb.tcp.port=5555, root
#   needed). Only with the owner's OK: it lets them manage the frame over Wi-Fi later,
#   but leaves a debug port open on their network (root-capable on rooted frames).
#   Without it, the frame's own setting is left as it was. revert.sh --restore-adb undoes it.
#
# --replace: if the installed VideoLoop was signed with a different key (another Mac, or a
#   lost debug.keystore), Android can't update it in place. With the user's OK this hands
#   the home screen back (revert.sh --uninstall), installs the new build, takes over again
#   and resumes the video that was playing. Videos, the frame's name and records are kept;
#   app settings (chosen video is restored, rotation is not) reset.
#
# Methods, in order of preference:
#   preferred  Android 7+: set VideoLoop as the default home (cmd package set-home-activity).
#              No root; the original home stays enabled.
#   disable    Android < 7 with root: disable the original home component (VideoLoop is
#              then the only home). Proven on the Allwinner astar-d7 Frameo frame.
#   chooser    Android < 7 without root: the user taps VideoLoop + "Always" once on the frame.
# Requires snapshot.sh to have run first. Upgrades keep the method of the first install.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

APK=""; METHOD=""; REPLACE=no; KEEP_ADB=no
i=0
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --method)  METHOD="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    --replace) REPLACE=yes; i=$((i+1)) ;;
    --keep-network-adb) KEEP_ADB=yes; i=$((i+1)) ;;
    *)         APK="${ARGS[$i]}"; i=$((i+1)) ;;
  esac
done
[ -f "$APK" ] || die "APK not found: $APK (build it with scripts/get_app.sh)"

ID="$(frame_id)"
ORIG_ENV="$FRAMES_DIR/$ID/original.env"
[ -f "$ORIG_ENV" ] || die "no original-state snapshot for this frame; run scripts/snapshot.sh -s $SERIAL first"
ORIG="$(kv_get "$ORIG_ENV" original_home)"
S="$(sdk)"
ROOT_MODE="$(root_mode)"
P="$(primary)"

# 1. Install / upgrade.
PREV_VIDEO=""
out="$(a install -r "$APK" 2>&1)"
echo "$out" | tail -2 >&2
if ! echo "$out" | grep -q Success; then
  echo "$out" | grep -qE 'UPDATE_INCOMPATIBLE|signatures do not match' || die "install failed"
  [ "$REPLACE" = yes ] || die "the VideoLoop on this frame was signed with a different key, so it can't be updated in place. Ask the user, then rerun with --replace: the frame briefly shows its original home screen, the old app is removed and the new one installed; videos, name and records stay, and the playing video resumes."
  # Remember what was playing, so the new install can carry on with it.
  PREV_VIDEO="$(a logcat -d -s VideoLoop:I 2>/dev/null | tr -d '\r' | grep -oE 'play /.*' | tail -1 | sed 's/^play //')"
  info "Different signing key: handing the home screen back and reinstalling (was playing: ${PREV_VIDEO:-unknown})"
  "$(dirname "$0")/revert.sh" -s "$SERIAL" --uninstall >&2 || die "couldn't hand the home screen back; nothing was installed"
  out="$(a install "$APK" 2>&1)"
  echo "$out" | tail -1 >&2
  echo "$out" | grep -q Success || die "reinstall failed; the frame is on its original home screen (run install_app.sh again)"
fi

# 2. Storage access (runtime permission since Android 6).
if [ "${S:-0}" -ge 23 ]; then
  for perm in READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
    sh_ "pm grant $APP_PKG android.permission.$perm" >/dev/null
  done
fi

# 3. Pick how to take over the home screen (an earlier install's method wins).
prev="$(sh_ cat "$P/$DEVICE_DIR/state" | sed -n 's/^method=//p')"
[ -n "$METHOD" ] || METHOD="$prev"
if [ -z "$METHOD" ]; then
  if [ "${S:-0}" -ge 24 ]; then METHOD=preferred
  elif [ "$ROOT_MODE" != none ] && [ -n "$ORIG" ]; then METHOD=disable
  else METHOD=chooser; fi
fi
info "Home-screen method: $METHOD (Android API $S, root: $ROOT_MODE, original home: ${ORIG:-none recorded})"

# 4. Tell the app how to undo this BEFORE switching, so its revert menu works from the start.
tmp="$(mktemp)"
printf 'method=%s\noriginal_home=%s\n' "$METHOD" "$ORIG" > "$tmp"
sh_ "mkdir -p $P/$DEVICE_DIR" >/dev/null
a push "$tmp" "$P/$DEVICE_DIR/state" >/dev/null 2>&1 || die "couldn't write $P/$DEVICE_DIR/state on the frame"
a push "$ORIG_ENV" "$P/$DEVICE_DIR/original.env" >/dev/null 2>&1
rm -f "$tmp"

# 5. Take over the home screen.
go_home() { a shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1; sleep 2; }
case "$METHOD" in
  preferred)
    run_ok "cmd package set-home-activity $APP_HOME" || die "Android refused set-home-activity; rerun with --method chooser (or disable, if rooted)"
    ;;
  disable)
    [ -n "$ORIG" ] || die "no original home recorded, so there is nothing to disable; use --method chooser"
    run_ok "pm disable $ORIG" root || die "couldn't disable $ORIG as root"
    ;;
  chooser) ;;
  *) die "unknown method: $METHOD" ;;
esac
# Re-enable our own home role in case an earlier revert turned it off.
run_ok "pm enable $APP_HOME" root >/dev/null 2>&1 || true
go_home

if ! is_videoloop "$(current_home)"; then
  echo "ACTION NEEDED: on the frame, choose 'VideoLoop' and tap 'Always' (waiting up to 2 minutes)"
  for i in $(seq 1 24); do
    is_videoloop "$(current_home)" && break
    sleep 5
  done
fi

# 6. Network adb after reboots: the owner's choice (see --keep-network-adb above).
persist="$(prop persist.adb.tcp.port)"
if [ -n "$persist" ]; then
  echo "network_adb_after_reboot=yes (the frame already keeps it on: persist.adb.tcp.port=$persist)"
elif [ "$KEEP_ADB" = yes ]; then
  if [ "$ROOT_MODE" = none ]; then
    warn "--keep-network-adb needs root, which this frame doesn't have; network adb will stop at the next reboot"
    echo "network_adb_after_reboot=no"
  else
    as_root "setprop persist.adb.tcp.port 5555" >/dev/null
    info "Set persist.adb.tcp.port=5555 (originally empty; revert.sh --restore-adb puts that back)"
    echo "network_adb_after_reboot=yes"
  fi
else
  echo "network_adb_after_reboot=no (unchanged; after a reboot, reach the frame by USB or re-enable adb on it)"
fi

NOW="$(current_home)"
echo "method=$METHOD"
echo "home_now=$NOW"
is_videoloop "$NOW" || die "the home screen is $NOW, not VideoLoop"

# 7. After a --replace, carry on with the video that was playing before.
if [ -n "$PREV_VIDEO" ] && [ "$(sh_ "[ -f '$PREV_VIDEO' ] && echo yes")" = yes ]; then
  a shell "am start -n $APP_MAIN -a $APP_PKG.PLAY --es path '$PREV_VIDEO'" >/dev/null 2>&1
  echo "resumed_video=$PREV_VIDEO"
fi
echo "RESULT: VideoLoop is the home screen"
