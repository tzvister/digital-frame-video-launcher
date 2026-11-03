#!/bin/bash
# Compare a frame with everything the CURRENT skill does, so frames set up by an older
# version of the skill can be brought up to date. Read-only.
#   scripts/checklist.sh -s <serial> [--verify]   check a connected frame item by item
#   scripts/checklist.sh --list                   every frame on record, and how current it is
# Each item prints OK, TODO (with the command that fixes it) or INFO (the user's choice).
# The result is saved to frames/<id>/checklist.txt with the checklist version.
#
# When the skill gains a step, add an item here and bump CHECKLIST_VERSION, so frames
# checked with an older list show up in --list as behind.
#   1 = snapshot, name, VideoLoop current + home, revert check, playback
#   2 = + security scan (hidden agents), Android/firmware updates off, no staged update,
#       network adb state
#   3 = + VideoLoop 2.4 (way back from Android Settings) and its overlay permission
#   4 = + original home app (Frameo) switched off or not; VideoLoop 2.5 (its revert
#       turns a switched-off original app back on)
#   5 = + VideoLoop 2.6 (no black flash between loops)
#   6 = + VideoLoop 2.7 (same, also on decoders that stop at the end, e.g. Allwinner)
CHECKLIST_VERSION=6
. "$(dirname "$0")/lib.sh"

if [ "$1" = --list ]; then
  printf '%-10s %-28s %-11s %-12s %s\n' NAME FRAME_ID SETUP CHECKLIST LAST_CHECKED
  for d in "$FRAMES_DIR"/*/; do
    [ -f "$d/original.env" ] || continue
    id="$(basename "$d")"
    name="$(kv_get "$d/frame.env" name)"
    setup="$(kv_get "$d/original.env" snapshot_time | cut -d' ' -f1)"
    v="$(kv_get "$d/checklist.txt" checklist_version)"
    at="$(kv_get "$d/checklist.txt" checked_at)"
    todo="$(kv_get "$d/checklist.txt" todo)"
    if [ -z "$v" ]; then st="never"
    elif [ "$v" -lt "$CHECKLIST_VERSION" ]; then st="v$v BEHIND"
    elif [ "$todo" != 0 ]; then st="v$v $todo TODO"
    else st="v$v OK"; fi
    printf '%-10s %-28s %-11s %-12s %s\n' "${name:--}" "$id" "${setup:--}" "$st" "${at:--}"
  done | sort
  echo "current checklist: v$CHECKLIST_VERSION. Frames marked never/BEHIND/TODO: connect them and run checklist.sh -s <serial>."
  exit 0
fi

parse_serial "$@"
ensure_connected
VERIFY=no
for o in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$o" in --verify) VERIFY=yes ;; *) die "unknown option $o" ;; esac
done

HERE="$(dirname "$0")"
ID="$(frame_id)"
P="$(primary)"
OUT=""; todo=0
item() {   # OK|TODO|INFO "<what>" ["<fix>"]
  local line
  line="$(printf '%-4s %s' "$1" "$2")"; [ -n "$3" ] && line="$line  -> $3"
  echo "$line"; OUT="$OUT$line
"
  [ "$1" = TODO ] && todo=$((todo + 1))
  return 0
}

echo "frame_id=$ID  name=$(frame_name)  checklist=v$CHECKLIST_VERSION"

# 1. Original state on record (Mac and frame), so revert can restore it.
mac_snap="$FRAMES_DIR/$ID/original.env"
dev_snap="$(sh_ "cat $P/$DEVICE_DIR/original.env" | grep -c '^original_home=')"
if [ -f "$mac_snap" ] && [ "${dev_snap:-0}" -gt 0 ]; then item OK "original state recorded on the Mac and the frame"
elif [ -f "$mac_snap" ] || [ "${dev_snap:-0}" -gt 0 ]; then item TODO "original state recorded in only one place" "scripts/snapshot.sh -s $SERIAL (recovers the missing copy)"
else item TODO "no original-state snapshot" "scripts/snapshot.sh -s $SERIAL"; fi

# 2. Named.
[ -n "$(frame_name)" ] && item OK "named: $(frame_name)" || item TODO "frame has no name" "scripts/set_name.sh -s $SERIAL \"<name>\""

# 3-6. Security (from security_scan.sh).
scan="$("$HERE/security_scan.sh" -s "$SERIAL" 2>/dev/null)"
sk() { echo "$scan" | sed -n "s/^$1=//p" | tail -1; }
agents="$(echo "$scan" | grep '^agent_' | grep -E '=(running|installed)')"
[ -z "$agents" ] && item OK "no known hidden agent installed or running" \
  || item TODO "hidden agent: $(echo $agents)" "references/security.md (neutralize, with the user's OK)"
[ -z "$(sk updaters_enabled)" ] && item OK "Android/firmware updates off$([ -n "$(sk updaters_disabled)" ] && echo " ($(sk updaters_disabled) disabled)")" \
  || item TODO "Android/firmware updates on: $(sk updaters_enabled)" "scripts/disable_updates.sh -s $SERIAL"
[ -z "$(sk updaters_running)" ] || item TODO "updater running now: $(sk updaters_running)" "scripts/disable_updates.sh -s $SERIAL, then check again"
[ -z "$(sk update_staged)" ] && item OK "no update waiting to install" \
  || item TODO "update waiting to install: $(sk update_staged)" "don't reboot; remove it as root (references/security.md)"
[ -n "$(sk outbound | grep '(root)')" ] && item TODO "root process talking to the internet: $(sk outbound)" "references/security.md"
item INFO "security scan: $(sk security)$([ "$(sk online)" = no ] && echo ', offline (outbound not checked)')"

# 7. Network adb: the user's choice, so report it.
if [ "$(prop persist.adb.tcp.port)" = 5555 ]; then item INFO "network adb on port 5555, kept after reboots" "turn off: scripts/network_adb.sh -s $SERIAL --off"
else item INFO "network adb off after reboots" "turn on (user's choice): scripts/network_adb.sh -s $SERIAL"; fi

# 8. The original home app (Frameo): still allowed to run in the background, or off.
oa="$("$HERE/original_app.sh" -s "$SERIAL" 2>/dev/null)"
oa_pkg="$(echo "$oa" | sed -n 's/^original_app=//p')"
if [ -n "$oa_pkg" ]; then
  if [ "$(echo "$oa" | sed -n 's/^original_app_state=//p')" = off ]; then
    item INFO "$oa_pkg switched off (no background runs, no self-updates)" "back on: scripts/original_app.sh -s $SERIAL --on"
  else
    item INFO "$oa_pkg still runs in the background$([ "$(echo "$oa" | sed -n 's/^original_app_running=//p')" = yes ] && echo ' (running now)')" "switch off (user's choice): scripts/original_app.sh -s $SERIAL --off"
  fi
fi

# 9. VideoLoop installed, current, and the home screen with an install record.
want="$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' "$REPO_DIR/AndroidManifest.xml" 2>/dev/null | head -1)"
have="$(sh_ dumpsys package "$APP_PKG" | grep -m1 versionName | sed 's/.*versionName=//')"
if [ -z "$have" ]; then item TODO "VideoLoop not installed" "steps 7-8 of SKILL.md (get_app.sh, install_app.sh)"
elif [ -n "$want" ] && [ "$have" != "$want" ]; then item TODO "VideoLoop $have installed, $want in the repo" "scripts/get_app.sh, then scripts/install_app.sh -s $SERIAL <apk>"
else item OK "VideoLoop $have (current)"; fi
if [ -n "$have" ]; then
  is_videoloop "$(current_home)" && item OK "VideoLoop is the home screen" \
    || item TODO "VideoLoop is not the home screen (now: $(current_home))" "scripts/install_app.sh -s $SERIAL <apk>"
  if [ "$(sdk)" -ge 23 ] 2>/dev/null; then
    sh_ "appops get $APP_PKG SYSTEM_ALERT_WINDOW" | grep -q allow \
      && item OK "can float the Back button over Android Settings" \
      || item TODO "no overlay permission: Android Settings would trap the user for 5 minutes" "scripts/install_app.sh -s $SERIAL <apk> (grants it)"
  fi
  sh_ "cat $P/$DEVICE_DIR/state" | grep -q '^method=' && item OK "install record on the frame" \
    || item TODO "no install record on the frame" "scripts/install_app.sh -s $SERIAL <apk>"
  # 10. The way back.
  "$HERE/revert.sh" -s "$SERIAL" --check 2>/dev/null | grep -q '^REVERT CHECK: OK' \
    && item OK "can be reverted to the original home screen" \
    || item TODO "revert check fails" "scripts/revert.sh -s $SERIAL --check (see its output)"
  # 11. Playback (20 s, so only on request).
  if [ "$VERIFY" = yes ]; then
    "$HERE/verify.sh" -s "$SERIAL" 2>/dev/null | grep -q '^RESULT: all checks passed' \
      && item OK "video plays and loops" || item TODO "playback check fails" "scripts/verify.sh -s $SERIAL"
  else item INFO "playback not checked" "rerun with --verify, or scripts/verify.sh -s $SERIAL"; fi
fi

echo "todo=$todo"
mkdir -p "$FRAMES_DIR/$ID"
{ echo "checklist_version=$CHECKLIST_VERSION"; echo "checked_at=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "todo=$todo"; printf '%s' "$OUT"; } > "$FRAMES_DIR/$ID/checklist.txt"
