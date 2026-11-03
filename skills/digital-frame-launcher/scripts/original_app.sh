#!/bin/bash
# Switch the frame's original home app (usually Frameo) off entirely, or back on.
#   scripts/original_app.sh -s <serial>          status (read-only)
#   scripts/original_app.sh -s <serial> --off    disable the whole package
#   scripts/original_app.sh -s <serial> --on     re-enable it
# Once VideoLoop is the home screen, Frameo still wakes up in the background (boot,
# network changes, alarms, push), goes online, keeps root shells and updates itself.
# Disabling the package stops all of that. Its photo sharing stops too: the user's call.
# Revert (revert.sh, and the app's own menu from VideoLoop 2.5) re-enables it first.
# Only while VideoLoop is the home screen, so the frame always has one.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

MODE=status
for o in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$o" in --off) MODE=off ;; --on) MODE=on ;; *) die "unknown option $o" ;; esac
done

P="$(primary)"
ID="$(frame_id)"
ORIG="$(sh_ cat "$P/$DEVICE_DIR/state" | sed -n 's/^original_home=//p')"
[ -n "$ORIG" ] || ORIG="$(kv_get "$FRAMES_DIR/$ID/original.env" original_home)"
PKG="${ORIG%%/*}"
[ -n "$PKG" ] || die "no original home app on record for this frame (run snapshot.sh / install_app.sh first)"
is_videoloop "$ORIG" && die "the recorded original home is VideoLoop itself; refusing"
ROOT_MODE="$(root_mode)"
REC="$FRAMES_DIR/$ID/original_app_off"

state() { pkg_disabled "$PKG" && echo off || echo on; }

case "$MODE" in
  off)
    is_videoloop "$(current_home)" || die "VideoLoop isn't the home screen; turning $PKG off now could leave the frame without one"
    if [ "$(state)" = on ]; then
      if [ "$ROOT_MODE" != none ]; then as_root "pm disable $PKG" >/dev/null
      else sh_ "pm disable-user $PKG" >/dev/null; fi
      [ "$(state)" = off ] || die "couldn't disable $PKG$([ "$ROOT_MODE" = none ] && echo ' (no root)')"
      wait_pkg_saved "$PKG" off || warn "$PKG is off, but Android hasn't saved it yet; wait a minute before rebooting"
    fi
    mkdir -p "$(dirname "$REC")"; echo "$PKG" > "$REC"
    is_videoloop "$(current_home)" || die "the home screen changed after disabling $PKG; check the frame"
    ;;
  on)
    if [ "$(state)" = off ]; then
      run_ok "pm enable $PKG" root 2>/dev/null || run_ok "pm enable $PKG" || die "couldn't re-enable $PKG"
      wait_pkg_saved "$PKG" on || warn "$PKG is on, but Android hasn't saved it yet; wait a minute before rebooting"
    fi
    rm -f "$REC"
    ;;
esac
running="$(sh_ ps | awk -v p="$PKG" '$NF==p || index($NF, p":")==1' | wc -l | tr -d ' ')"
echo "original_app=$PKG"
echo "original_app_state=$(state)"
echo "original_app_running=$([ "${running:-0}" -gt 0 ] && echo yes || echo no)"
