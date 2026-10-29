#!/bin/bash
# Find the frame on the LAN and print its adb address (ip:5555).
#   devices/astar-d7/find-frame.sh            -> prints e.g. 192.168.1.50:5555
#   . devices/astar-d7/find-frame.sh          -> defines find_frame for other scripts
#
# Cheap frames often pick a new random Wi-Fi MAC, and so a new DHCP IP, on every
# boot. The frame is identified by its product name over adb, not by address:
#   FRAME_DEVICE      ro.product.device to look for   (default astar-d7)
#   FRAME_MAC_PREFIX  Wi-Fi vendor prefix to try first (default 00:e0:4c, Realtek)
#   FRAME_NETS        networks to sweep, e.g. "192.168.1.0/24" (default: the Mac's own)

_FF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Is ip:5555 the frame? Its Wi-Fi dozes (replies can take ~1 s and connects can
# fail), and a stale "offline" adb transport makes every command fail, so start
# from a fresh connection and retry.
is_frame() {
  local cand="$1" dev="" try
  adb disconnect "$cand" >/dev/null 2>&1
  for try in 1 2 3; do
    adb connect "$cand" >/dev/null 2>&1
    dev="$(adb -s "$cand" shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
    [ -n "$dev" ] && break
    sleep 1
  done
  [ "$dev" = "${FRAME_DEVICE:-astar-d7}" ]
}

find_frame() {
  local cand prefix hit
  # Fast path: hosts the Mac already knows with the frame's Wi-Fi vendor prefix
  # (the random MAC keeps the vendor part). macOS prints "0:e0:4c" for 00:e0:4c.
  prefix="$(echo "${FRAME_MAC_PREFIX:-00:e0:4c}" | sed 's/^0//')"
  for cand in $(arp -an 2>/dev/null | grep -iE " 0?$prefix:" | grep -oE '\([0-9.]+\)' | tr -d '()'); do
    if is_frame "$cand:5555"; then echo "$cand:5555"; return 0; fi
  done
  # Full sweep of the Mac's networks (or FRAME_NETS) with the skill's finder.
  hit="$("$_FF_ROOT/skills/digital-frame-launcher/scripts/find_frames.sh" 2>/dev/null \
    | awk -F ' [|] ' -v dev="${FRAME_DEVICE:-astar-d7}" 'index($4, dev "/") == 1 {print $1; exit}')"
  [ -n "$hit" ] && echo "$hit"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  find_frame || { echo "Frame not found on the network." >&2; exit 1; }
fi
