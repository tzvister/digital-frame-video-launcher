#!/bin/bash
# Install (or upgrade) VideoLoop and make it the frame's home screen, recording how,
# so that revert.sh and the app's own menu can undo exactly that.
#   scripts/install_app.sh -s <serial> <VideoLoop.apk> [--method preferred|disable|chooser]
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

APK="${ARGS[0]}"
METHOD=""
[ "${ARGS[1]}" = "--method" ] && METHOD="${ARGS[2]}"
[ -f "$APK" ] || die "APK not found: $APK (build it with scripts/get_app.sh)"

ID="$(frame_id)"
ORIG_ENV="$FRAMES_DIR/$ID/original.env"
[ -f "$ORIG_ENV" ] || die "no original-state snapshot for this frame; run scripts/snapshot.sh -s $SERIAL first"
ORIG="$(kv_get "$ORIG_ENV" original_home)"
S="$(sdk)"
ROOT_MODE="$(root_mode)"
P="$(primary)"

# 1. Install / upgrade.
out="$(a install -r "$APK" 2>&1)"
echo "$out" | tail -2 >&2
if ! echo "$out" | grep -q Success; then
  echo "$out" | grep -q UPDATE_INCOMPATIBLE && die "a VideoLoop signed with a different key is installed. It must be uninstalled first (ask the user; make sure another home screen is enabled before uninstalling the current one)."
  die "install failed"
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

if [ "$METHOD" = chooser ] || ! is_videoloop "$(current_home)"; then
  echo "ACTION NEEDED: on the frame, choose 'VideoLoop' and tap 'Always' (waiting up to 2 minutes)"
  for i in $(seq 1 24); do
    is_videoloop "$(current_home)" && break
    sleep 5
  done
fi

# 6. Keep network adb on across reboots, when we're connected over the network and can.
case "$SERIAL" in
  *:*)
    if [ -z "$(prop persist.adb.tcp.port)" ] && [ "$ROOT_MODE" != none ]; then
      as_root "setprop persist.adb.tcp.port 5555" >/dev/null
      info "Set persist.adb.tcp.port=5555 so network adb survives reboots (original value recorded: empty)"
    fi ;;
esac

NOW="$(current_home)"
echo "method=$METHOD"
echo "home_now=$NOW"
is_videoloop "$NOW" && echo "RESULT: VideoLoop is the home screen" || die "the home screen is $NOW, not VideoLoop"
