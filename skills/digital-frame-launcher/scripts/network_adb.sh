#!/bin/bash
# Network adb on port 5555, now and after every reboot, so the frame can be managed over Wi-Fi.
#   scripts/network_adb.sh -s <serial>          turn it on
#   scripts/network_adb.sh -s <serial> --off    turn it off (now if on USB, else after a reboot)
# Only with the owner's OK: it leaves a debug port open on their network, root-capable on
# rooted frames. Keeping it on after reboots needs root (persist.adb.tcp.port); without
# root it lasts until the next reboot. Needs the snapshot (scripts/snapshot.sh) first, so
# the original setting is on record: revert.sh --restore-adb puts that back.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

PORT=5555
OFF=no
for o in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$o" in --off) OFF=yes ;; *) die "unknown option $o" ;; esac
done

[ -f "$FRAMES_DIR/$(frame_id)/original.env" ] || \
  die "no original-state snapshot for this frame; run scripts/snapshot.sh -s $SERIAL first"
ROOT_MODE="$(root_mode)"

# Is adbd listening on the port right now? (/proc/net/tcp: local port in hex, state 0A.)
listening() {
  local hex; hex="$(printf ':%04X ' "$PORT")"
  sh_ 'cat /proc/net/tcp /proc/net/tcp6' | awk '$4=="0A"{print $2" "}' | grep -q "$hex"
}
usb() { case "$SERIAL" in *:*) return 1 ;; *) return 0 ;; esac; }

if [ "$OFF" = yes ]; then
  [ "$ROOT_MODE" != none ] && as_root 'setprop persist.adb.tcp.port ""' >/dev/null
  if usb; then
    a usb >/dev/null 2>&1   # restarts adbd on USB only
    sleep 3; adb -s "$SERIAL" wait-for-device
  else
    info "Connected over the network, so it stays on until the next reboot."
  fi
  echo "network_adb_after_reboot=$([ -n "$(prop persist.adb.tcp.port)" ] && echo yes || echo no)"
  exit 0
fi

# Keep it on after reboots (root only).
if [ "$ROOT_MODE" = none ]; then
  warn "no root: network adb will be on until the next reboot only"
elif [ "$(prop persist.adb.tcp.port)" != "$PORT" ]; then
  orig="$(prop persist.adb.tcp.port)"
  as_root "setprop persist.adb.tcp.port $PORT" >/dev/null
  info "Set persist.adb.tcp.port=$PORT (was '${orig}'; revert.sh --restore-adb puts that back)"
fi

# Turn it on now. 'adb tcpip' restarts adbd cleanly (stopping adbd from an adb shell
# would kill that shell before it could start it again). USB keeps working.
if ! listening; then
  a tcpip "$PORT" >/dev/null 2>&1
  sleep 3
  usb && adb -s "$SERIAL" wait-for-device
  case "$SERIAL" in *:*) ensure_connected ;; esac
fi

listening && now=yes || now=no
echo "network_adb_now=$now"
echo "network_adb_after_reboot=$([ "$(prop persist.adb.tcp.port)" = "$PORT" ] && echo yes || echo no)"

# Try it over Wi-Fi if the frame has an address.
wifi="$(sh_ ls /sys/class/net | tr -s ' \t' '\n\n' | grep -E '^(wlan|wlp|eth)' | head -1)"
ip=""; [ -n "$wifi" ] && ip="$(sh_ "ip -4 addr show $wifi" | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)"
if [ -z "$ip" ]; then
  echo "connect=not on Wi-Fi yet; once it is: adb connect <frame-ip>:$PORT"
elif adb connect "$ip:$PORT" >/dev/null 2>&1 && [ "$(adb -s "$ip:$PORT" get-state 2>/dev/null | tr -d '\r')" = device ]; then
  echo "connect=$ip:$PORT OK"
else
  echo "connect=$ip:$PORT failed (accept the debugging prompt on the frame, or check the Mac is on the same network)"
fi
[ "$now" = yes ] || die "adbd is not listening on port $PORT"
