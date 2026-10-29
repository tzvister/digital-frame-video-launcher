#!/bin/bash
# List Android devices reachable over adb: USB devices plus a LAN scan for adb on port 5555.
#   scripts/find_frames.sh                         scan the Mac's own networks
#   FRAME_NETS="192.168.1.0/24" scripts/find_frames.sh
# One line per device:  SERIAL | maker model | Android (API) | device/platform | VideoLoop
# Read-only. Frames on dozing Wi-Fi can take ~1 s to answer, so each host gets 3 s.
. "$(dirname "$0")/lib.sh"

ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
mask_bits() {   # 0xfffffc00 or 255.255.252.0 -> 22
  local n bits=0
  case "$1" in 0x*) n=$(( $1 )) ;; *) n=$(ip2int "$1") ;; esac
  while [ "$n" -gt 0 ]; do bits=$(( bits + (n & 1) )); n=$(( n >> 1 )); done
  echo "$bits"
}

# The Mac's own local networks as ip/bits. VPN and virtual adapters (Tailscale, Docker,
# VMs, ...) and the CGNAT range VPNs use are skipped: frames sit on the home LAN, and
# sweeping a VPN could reach devices that aren't the user's.
networks() {
  if [ -n "$FRAME_NETS" ]; then echo "$FRAME_NETS" | tr ' ,' '\n\n'; return; fi
  {
    if command -v ifconfig >/dev/null 2>&1; then
      ifconfig 2>/dev/null | awk '
        /^[^ \t]/ { iface = $1; sub(/:$/, "", iface) }
        $1 == "inet" { ip = $2; sub(/^addr:/, "", ip); m = $4; sub(/^Mask:/, "", m); print iface, ip, m }'
    elif command -v ip >/dev/null 2>&1; then
      ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print $2, a[1], "/" a[2] }'
    fi
  } | while read -r iface ip mask; do
    case "$iface" in
      lo*|utun*|ipsec*|gif*|stf*|awdl*|llw*|bridge*|vmnet*|vboxnet*|docker*|br-*|veth*|virbr*|tailscale*|zt*|wg*|tun*|tap*|anpi*) continue ;;
    esac
    case "$ip" in 127.*|169.254.*|"") continue ;; esac
    o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"
    [ "$o1" = 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && continue   # CGNAT (VPNs)
    case "$mask" in /*) bits="${mask#/}" ;; *) bits="$(mask_bits "$mask")" ;; esac
    [ "$bits" -lt 22 ] && bits=24      # don't sweep huge networks; the Mac's own /24 only
    echo "$ip/$bits"
  done
}

port_open() {   # host -> exit 0 if adb's port answers within 3 s
  if [ "$(uname)" = Darwin ]; then nc -G3 -z -w3 "$1" 5555 >/dev/null 2>&1
  else nc -z -w3 "$1" 5555 >/dev/null 2>&1; fi
}

scan_net() {    # a.b.c.d/bits -> prints ip:5555 for every host with port 5555 open
  local ip="${1%/*}" bits="${1#*/}" base size i
  [ "$bits" = "$1" ] && bits=32                       # a bare IP means just that host
  if [ "$bits" -ge 31 ]; then port_open "$ip" && echo "$ip:5555"; return; fi
  base=$(( $(ip2int "$ip") & ((0xffffffff << (32 - bits)) & 0xffffffff) ))
  size=$(( 1 << (32 - bits) ))
  i=1
  while [ "$i" -lt $(( size - 1 )) ]; do
    h=$(int2ip $(( base + i )))
    ( port_open "$h" && echo "$h:5555" ) &
    [ $(( i % 256 )) -eq 0 ] && wait
    i=$(( i + 1 ))
  done
  wait
}

describe() {    # serial -> one summary line
  local S="$1" st t g vl
  case "$S" in
    *:*) adb disconnect "$S" >/dev/null 2>&1
         for t in 1 2 3; do
           adb connect "$S" >/dev/null 2>&1
           st="$(adb -s "$S" get-state 2>/dev/null | tr -d '\r')"
           [ "$st" = device ] && break; sleep 1
         done ;;
    *)   st="$(adb -s "$S" get-state 2>/dev/null | tr -d '\r')" ;;
  esac
  if [ "$st" != device ]; then
    st="$(adb devices | tr -d '\r' | awk -v s="$S" '$1==s{print $2}')"
    echo "$S | adb not usable: ${st:-no answer}$([ "$st" = unauthorized ] && echo ' (accept the debugging prompt on the frame)')"
    return
  fi
  g() { adb -s "$S" shell getprop "$1" 2>/dev/null | tr -d '\r'; }
  vl="$(adb -s "$S" shell dumpsys package "$APP_PKG" 2>/dev/null | tr -d '\r' | grep -m1 versionName | sed 's/.*versionName=//')"
  nm="$(adb -s "$S" shell 'cat "${EXTERNAL_STORAGE:-/sdcard}/.videoloop/name" 2>/dev/null' 2>/dev/null \
        | tr -d '\r' | grep -v -i 'no such' | head -1)"
  # The name goes last so the earlier fields keep their positions for tools that parse them.
  echo "$S | $(g ro.product.manufacturer) $(g ro.product.model) | Android $(g ro.build.version.release) (API $(g ro.build.version.sdk)) | $(g ro.product.device)/$(g ro.board.platform) | VideoLoop: ${vl:-not installed}${nm:+ | name: $nm}"
}

command -v adb >/dev/null || die "adb not found. Install it: brew install android-platform-tools"

usb="$(adb devices | tr -d '\r' | awk 'NR > 1 && $1 != "" && $1 !~ /:/ {print $1}')"
nets="$(networks)"
info "Scanning for adb (port 5555) on: $(echo $nets) ..."
hits="$(for n in $nets; do scan_net "$n"; done | sort -u)"

found=0
for s in $usb $hits; do describe "$s"; found=1; done
[ "$found" = 1 ] || { echo "No devices found over USB or on the network."; exit 1; }
