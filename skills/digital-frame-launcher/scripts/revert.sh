#!/bin/bash
# Put the frame back on its ORIGINAL home screen, undoing exactly what install_app.sh did.
#   scripts/revert.sh -s <serial> --check        read-only: can this frame be reverted?
#   scripts/revert.sh -s <serial> [--uninstall] [--restore-adb] [--clean]
#     --uninstall    also remove the VideoLoop app (default: keep it, just not as home)
#     --restore-adb  put persist.adb.tcp.port back to its original value. If that was
#                    empty, network adb is OFF after the next reboot. Default: leave it.
#     --clean        also delete VideoLoop's own records (<storage>/.videoloop)
# Videos in <storage>/VideoLoop are never touched; they belong to the user.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

CHECK=no; UNINSTALL=no; RESTORE_ADB=no; CLEAN=no
for o in "${ARGS[@]}"; do
  case "$o" in
    --check) CHECK=yes ;; --uninstall) UNINSTALL=yes ;;
    --restore-adb) RESTORE_ADB=yes ;; --clean) CLEAN=yes ;;
    *) die "unknown option $o" ;;
  esac
done

P="$(primary)"
S="$(sdk)"
ROOT_MODE="$(root_mode)"
ID="$(frame_id)"
LOCAL_ENV="$FRAMES_DIR/$ID/original.env"

# What install_app.sh recorded: the frame's copy first, the Mac's as a fallback.
state="$(sh_ cat "$P/$DEVICE_DIR/state")"
METHOD="$(echo "$state" | sed -n 's/^method=//p')"
ORIG="$(echo "$state" | sed -n 's/^original_home=//p')"
legacy="$(sh_ cat "$P/$DEVICE_DIR/frameo_home" | grep '/' | head -1)"
if [ -z "$METHOD" ] && [ -n "$legacy" ]; then METHOD=disable; ORIG="$legacy"; fi      # VideoLoop 1.x
[ -n "$ORIG" ] || ORIG="$(kv_get "$LOCAL_ENV" original_home)"
ADB_ORIG="$(kv_get "$LOCAL_ENV" adb_tcp_persist)"
[ -f "$LOCAL_ENV" ] || ADB_ORIG="$(sh_ cat "$P/$DEVICE_DIR/original.env" | sed -n 's/^adb_tcp_persist=//p')"

echo "method=${METHOD:-unknown}"
echo "original_home=${ORIG:-none recorded}"
echo "root=$ROOT_MODE"

# ---- can we revert? ----
problems=""
[ -n "$METHOD" ] || problems="$problems no install record on the frame ($P/$DEVICE_DIR/state);"
if [ -n "$ORIG" ]; then
  opkg="${ORIG%%/*}"
  sh_ "pm path $opkg" | grep -q '^package:' || problems="$problems the original home app $opkg is no longer installed;"
fi
if [ "$METHOD" = disable ] && [ "$ROOT_MODE" = none ]; then
  problems="$problems the original home was disabled with root, and root is no longer available;"
fi
if [ "$CHECK" = yes ]; then
  if [ -z "$problems" ]; then echo "REVERT CHECK: OK - this frame can be put back on ${ORIG:-its previous home screen}"; exit 0; fi
  echo "REVERT CHECK: PROBLEM -$problems"; exit 1
fi
[ -z "$problems" ] || warn "continuing despite:$problems"

# ---- 1. bring the original home back ----
case "$METHOD" in
  disable)   [ -n "$ORIG" ] && { run_ok "pm enable $ORIG" root || die "couldn't re-enable $ORIG as root; VideoLoop left in place"; } ;;
  preferred) [ -n "$ORIG" ] && [ "${S:-0}" -ge 24 ] && run_ok "cmd package set-home-activity $ORIG" ;;
  chooser|"") ;;
esac

# ---- 2. make sure another home exists before VideoLoop steps aside ----
other=yes
if [ "${S:-0}" -ge 24 ]; then
  home_candidates | grep -v "^$APP_PKG/" | grep -q '/' || other=no
elif [ -n "$ORIG" ]; then
  # Older Android: the original component must not be in its package's disabled list.
  cls="${ORIG#*/}"; case "$cls" in .*) cls="${ORIG%%/*}$cls" ;; esac
  sh_ "dumpsys package ${ORIG%%/*}" | awk '/disabledComponents:/{f=1; next} f && /:/{f=0} f' \
    | grep -q "$cls" && other=no
fi
[ "$other" = yes ] || die "no other home screen is enabled, so VideoLoop stays (the frame would have none). Original: ${ORIG:-unknown}"

# ---- 3. VideoLoop steps aside ----
if [ "$UNINSTALL" = yes ]; then
  run_ok "pm uninstall $APP_PKG" || die "uninstall failed"
elif ! run_ok "pm disable $APP_HOME" root 2>/dev/null; then
  # No root: ask the app to turn off its own home role (it re-checks safety itself).
  a shell "am start -n $APP_MAIN -a $APP_PKG.REVERT --es confirm yes" >/dev/null 2>&1
  sleep 2
fi

# ---- 4. optional extras ----
if [ "$RESTORE_ADB" = yes ]; then
  if [ -n "$ADB_ORIG" ]; then as_root "setprop persist.adb.tcp.port $ADB_ORIG" >/dev/null
  else as_root 'setprop persist.adb.tcp.port ""' >/dev/null; fi
  info "persist.adb.tcp.port restored to '${ADB_ORIG}'$([ -z "$ADB_ORIG" ] && echo ' (network adb will be off after the next reboot)')"
fi
[ "$CLEAN" = yes ] && sh_ "rm -r $P/$DEVICE_DIR" >/dev/null && info "Removed $P/$DEVICE_DIR"

a shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
sleep 2
NOW="$(current_home)"
echo "home_now=$NOW"
if is_videoloop "$NOW"; then
  echo "RESULT: VideoLoop still answers HOME right now; it will step aside after a reboot (adb reboot)."
else
  echo "RESULT: the frame is back on ${NOW:-its original home screen}"
fi
