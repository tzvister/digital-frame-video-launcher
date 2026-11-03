#!/bin/bash
# Turn off Android/firmware updates: disable every vendor updater package (Adups FOTA,
# Rockchip RKUpdateService, ...). Frameo's own "Android update" screen hands off to these.
#   scripts/disable_updates.sh -s <serial>          disable the enabled ones
#   scripts/disable_updates.sh -s <serial> --undo   re-enable the ones this script disabled
# Records what it disabled on the Mac (frames/<id>/updates_disabled) and on the frame
# (<storage>/.videoloop/updates_disabled), so --undo touches only those.
# Android saves package state to disk lazily; a reboot before that loses the change,
# so this waits until package-restrictions.xml has it (root) before reporting done.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

UNDO=no
for o in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$o" in --undo) UNDO=yes ;; *) die "unknown option $o" ;; esac
done

ROOT_MODE="$(root_mode)"
P="$(primary)"
REC_MAC="$FRAMES_DIR/$(frame_id)/updates_disabled"
REC_DEV="$P/$DEVICE_DIR/updates_disabled"
mkdir -p "$(dirname "$REC_MAC")"

pm_set() {   # enable|disable <pkg>
  if [ "$ROOT_MODE" != none ]; then as_root "pm $1 $2"
  elif [ "$1" = disable ]; then sh_ "pm disable-user $2"
  else sh_ "pm enable $2"; fi
}
# Wait until Android has written the state to disk (needs root to read; else skip).
saved() {    # <pkg> <want: 2=disabled|1=enabled>
  [ "$ROOT_MODE" = none ] && return 0
  as_root "cat /data/system/users/0/package-restrictions.xml" \
    | grep -E "name=\"$1\"" | grep -q "enabled=\"$2\"" && return 0
  [ "$2" = 1 ] && ! as_root "cat /data/system/users/0/package-restrictions.xml" \
    | grep -E "name=\"$1\"" | grep -q 'enabled="[234]"'
}
wait_saved() {
  local i
  for i in $(seq 1 45); do saved "$1" "$2" && return 0; sleep 2; done
  return 1
}

if [ "$UNDO" = yes ]; then
  list="$(cat "$REC_MAC" 2>/dev/null)"
  [ -n "$list" ] || list="$(sh_ "cat $REC_DEV" | grep -v -i 'no such')"
  [ -n "$list" ] || die "no record of updaters disabled by this script on this frame"
  for p in $list; do
    pm_set enable "$p" >/dev/null
    wait_saved "$p" 1 && echo "enabled $p" || warn "$p: enabled, but not yet saved to disk; wait before rebooting"
  done
  rm -f "$REC_MAC"; sh_ "rm $REC_DEV" >/dev/null
  echo "updates=on"
  exit 0
fi

todo="$(updater_packages | awk '$2=="enabled"{print $1}')"
done_list="$(cat "$REC_MAC" 2>/dev/null)"
fail=0
for p in $todo; do
  pm_set disable "$p" >/dev/null
  if updater_packages | grep -qx "$p disabled"; then
    done_list="$done_list $p"
    wait_saved "$p" 2 && echo "disabled $p" || { warn "$p: disabled, but not yet saved to disk; wait a minute before rebooting"; fail=1; }
  else
    warn "could not disable $p$([ "$ROOT_MODE" = none ] && echo ' (no root)')"; fail=1
  fi
done
done_list="$(echo $done_list | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$done_list" ]; then
  echo "$done_list" > "$REC_MAC"
  sh_ "mkdir -p $P/$DEVICE_DIR; echo '$done_list' > $REC_DEV" >/dev/null
fi
left="$(updater_packages | awk '$2=="enabled"{print $1}' | tr '\n' ' ' | sed 's/ $//')"
echo "updaters_enabled=$left"
echo "updates=$([ -z "$left" ] && echo off || echo on)"
[ -z "$left" ] && [ "$fail" = 0 ]
