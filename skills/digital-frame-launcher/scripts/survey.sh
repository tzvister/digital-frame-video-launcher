#!/bin/bash
# Read-only compatibility survey of a frame. Changes nothing on the frame.
#   scripts/survey.sh -s <serial>          prints key=value lines
# Ends with verdict=ok|warn|block and a notes= line explaining any warnings.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

kv() { printf '%s=%s\n' "$1" "$2"; }

S="$(sdk)"
R="$(root_mode)"
P="$(primary)"
HOME_NOW="$(current_home)"

kv serial "$SERIAL"
kv frame_id "$(frame_id)"
kv frame_name "$(frame_name)"
kv manufacturer "$(prop ro.product.manufacturer)"
kv model "$(prop ro.product.model)"
kv device "$(prop ro.product.device)"
kv board "$(prop ro.product.board)"
kv platform "$(prop ro.board.platform)"
kv hardware "$(prop ro.hardware)"
kv android "$(prop ro.build.version.release)"
kv sdk "$S"
kv abi "$(prop ro.product.cpu.abi)"
kv build_type "$(prop ro.build.type)"
kv fingerprint "$(prop ro.build.fingerprint)"
kv root "$R"
kv display "$(sh_ wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)"
kv density "$(sh_ wm density | grep -oE '[0-9]+' | tail -1)"
acc="$(sh_ dumpsys sensorservice | grep -ci accelerometer)"
kv accelerometer "$([ "${acc:-0}" -gt 0 ] && echo yes || echo no)"
kv home_current "$HOME_NOW"
kv home_candidates "$(home_candidates | tr '\n' ' ')"
kv primary_storage "$P"
kv primary_free "$(sh_ df "$P" | tail -1 | tr -s ' ')"
kv removable_mounts "$(sh_ cat /proc/mounts | awk '
  $2 ~ /^\/(storage|mnt)\// && $2 !~ /emulated|^\/mnt\/(runtime|user|asec|obb|secure|expand)/ &&
  $3 ~ /^(vfat|exfat|ntfs|fuseblk|texfat|sdfat|fuse|sdcardfs|esdfs)$/ {printf "%s(%s) ", $2, $3}')"
[ "$S" -ge 23 ] 2>/dev/null && kv volumes "$(sh_ sm list-volumes all | grep -v '^$' | tr '\n' ';')"

wifi="$(sh_ ls /sys/class/net | tr -s ' \t' '\n\n' | grep -E '^(wlan|wlp|eth)' | head -1)"
kv wifi_iface "$wifi"
if [ -n "$wifi" ]; then
  kv wifi_mac "$(sh_ cat /sys/class/net/$wifi/address)"
  ip="$(sh_ "ip -4 addr show $wifi" | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)"
  [ -n "$ip" ] || ip="$(prop dhcp.$wifi.ipaddress)"
  kv ip "$ip"
fi
kv adb_tcp_persist "$(prop persist.adb.tcp.port)"
kv adb_tcp_service "$(prop service.adb.tcp.port)"

avc="$(sh_ 'cat /vendor/etc/media_codecs*.xml /system/etc/media_codecs*.xml /odm/etc/media_codecs*.xml' | grep -ci 'video/avc')"
kv h264_decoder "$([ "${avc:-0}" -gt 0 ] && echo yes || echo unknown)"

vl="$(sh_ dumpsys package "$APP_PKG" | grep -m1 versionName | sed 's/.*versionName=//')"
kv videoloop "${vl:-none}"
kv videoloop_state "$(sh_ cat "$P/$DEVICE_DIR/state" 2>/dev/null | grep -E '^(method|original_home)=' | tr '\n' ' ')"

# ---- verdict ----
verdict=ok
notes=""
note() { notes="$notes $1;"; [ "$verdict" = ok ] && verdict=warn; }
if [ "${S:-0}" -lt 19 ]; then
  verdict=block; notes="$notes Android older than 4.4 (API 19) is not supported;"
fi
if [ "$R" = none ] && [ "${S:-0}" -lt 24 ]; then
  note "no root and Android below 7: making VideoLoop the home screen needs one tap on 'Always' on the frame, and raw firmware backup is not possible"
elif [ "$R" = none ]; then
  note "no root: raw firmware backup is not possible (revert does not need it)"
fi
[ "${avc:-0}" -gt 0 ] || note "could not confirm an H.264 decoder from the codec lists; the test video will tell"
[ "${S:-0}" = 23 ] || note "VideoLoop is field-tested on Android 6 (API 23); this version is supported by design but not yet tested"
case "$HOME_NOW" in
  *ResolverActivity*|"") note "no default home screen is set (Android shows a chooser)" ;;
  "$APP_PKG"/*)          note "VideoLoop is already the home screen: use the upgrade or revert flow" ;;
esac
[ "$vl" != "" ] && ! is_videoloop "$HOME_NOW" && note "VideoLoop $vl is installed but is not the home screen"
kv verdict "$verdict"
kv notes "${notes# }"
