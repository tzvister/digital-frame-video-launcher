#!/bin/bash
# Read-only security check of a frame, run before deploying VideoLoop. Changes nothing.
#   scripts/security_scan.sh -s <serial>          prints key=value lines
# Looks for hidden root agents (iotv), vendor firmware updaters, hard-coded DNS,
# apps holding root shells, open ports and live connections, and a wrong clock.
# Ends with security=clean|review|risk and a notes= line. See references/security.md.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

kv() { printf '%s=%s\n' "$1" "$2"; }

# Known hidden agents: "<name> <binary> <launcher script>". Add new ones here and
# in references/security.md.
AGENTS="iotv /system/bin/iotv /system/bin/run_iotv.sh"
# Package-name fragments of vendor over-the-air updaters (they can reinstall an agent).
UPDATER_RE='fota|adups|rockchip\.update|\.ota$|\.ota\.|otaupdate|systemupdate|update\.service|upgrade'
PUBLIC_DNS_RE='^(8\.8\.[48]\.[48]|1\.[01]\.[01]\.1|9\.9\.9\.9|208\.67\.22[02]\.22[02]|114\.114\.1[14]4\.1[14]4|223\.5\.5\.5|180\.76\.76\.76)$'

R="$(root_mode)"
ROOT_MODE="$R"
# Toolbox ps (Android <= 7) lists everything and treats -A as a name filter; toybox needs -A.
PS="$(sh_ 'ps -A')"
[ "$(echo "$PS" | wc -l)" -gt 2 ] || PS="$(sh_ ps)"
# Some firmware's pidof returns every PID on the system, so never trust it: go by ps.
pids_of() { echo "$PS" | awk -v n="$1" '$NF==n || $NF ~ ("/" n "$") {print $2}' | tr '\n' ' ' | sed 's/ $//'; }

risk=""; review=""
flag_risk()   { risk="$risk $1;"; }
flag_review() { review="$review $1;"; }

kv security_patch "$(prop ro.build.version.security_patch)"
kv selinux "$(sh_ getenforce)"
kv build "$(prop ro.build.type)/$(prop ro.build.tags)"
kv root "$R"
kv adb_auth "$([ "$(prop ro.adb.secure)" = 1 ] && echo required || echo off)"
adb_tcp="$(prop service.adb.tcp.port)"; [ -n "$adb_tcp" ] || adb_tcp="$(prop persist.adb.tcp.port)"
kv adb_network_port "$adb_tcp"

# ---- hidden agents ----
found=""
set -- $AGENTS
while [ $# -ge 3 ]; do
  name="$1"; bin="$2"; launcher="$3"; shift 3
  pid="$(pids_of "$name")"
  has_bin="$(sh_ "ls $bin" | grep -v -i 'no such')"
  has_launcher="$(sh_ "ls $launcher" | grep -v -i 'no such')"
  if [ -n "$pid" ]; then state="running(pid $pid)"
  elif [ -n "$has_bin" ]; then state=installed
  elif [ -n "$has_launcher" ]; then state=neutralized
  else state=absent; fi
  kv "agent_$name" "$state"
  case "$state" in
    running*|installed) found="$found $name"
      flag_risk "hidden root agent '$name' is $state: deal with it before this frame goes on a network you care about" ;;
  esac
done

# ---- vendor updaters ----
all_pkgs="$(sh_ pm list packages | sed 's/^package://')"
off_pkgs="$(sh_ pm list packages -d | sed 's/^package://')"
upd_on=""; upd_off=""
for p in $(echo "$all_pkgs" | grep -iE "$UPDATER_RE"); do
  if echo "$off_pkgs" | grep -qx "$p"; then upd_off="$upd_off $p"; else upd_on="$upd_on $p"; fi
done
kv updaters_enabled "${upd_on# }"
kv updaters_disabled "${upd_off# }"
if [ -n "$upd_on" ]; then
  if [ -n "$found" ]; then flag_risk "vendor updaters are enabled and could reinstall$found after it is removed"
  else flag_review "vendor updaters are enabled (they can install new firmware over Wi-Fi without asking)"; fi
fi

# ---- DNS ----
resolv="$(sh_ 'cat /system/etc/resolv.conf' | grep -v -i 'no such' | awk '/^nameserver/{print $2}' | tr '\n' ' ' | sed 's/ $//')"
kv resolv_conf_dns "$resolv"
pub=""
for d in $resolv; do echo "$d" | grep -qE "$PUBLIC_DNS_RE" && pub="$pub $d"; done
[ -n "$pub" ] && flag_review "DNS is hard-coded to public servers ($(echo $pub | tr ' ' ',')), so DNS blocking on the router won't apply; isolate it by firewall instead"

# ---- root held by apps ----
holders=""
for ppid in $(echo "$PS" | awk '$NF=="su" && $1 ~ /^u[0-9]+_/ {print $3}' | sort -u); do
  holder="$(echo "$PS" | awk -v p="$ppid" '$2==p {print $NF}')"
  holders="$holders ${holder:-pid$ppid}"
done
holders="$(echo $holders | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
kv root_shells_held_by "$holders"
[ -n "$holders" ] && flag_review "these apps keep root shells open: $holders"

# ---- sockets: who listens beyond localhost, and who is talking out ----
# /proc/net/tcp rows: local rem state ... uid. State 0A = listen, 01 = established.
listen=""; conns=""
for f in /proc/net/tcp /proc/net/tcp6; do
  rows="$(sh_ "cat $f" | awk 'NR>1 {print $2, $3, $4, $8}')"
  [ -n "$rows" ] || continue
  while read -r loc rem st uid; do
    lip="${loc%:*}"; lport=$((16#${loc##*:}))
    case "$st" in
      0A) case "$lip" in 0100007F|*0100007F|00000000000000000000000001000000) ;;  # loopback
            *) listen="$listen $lport(uid $uid)" ;; esac ;;
      01) rip="${rem%:*}"; rport=$((16#${rem##*:}))
          if [ ${#rip} -eq 8 ]; then
            ip="$((16#${rip:6:2})).$((16#${rip:4:2})).$((16#${rip:2:2})).$((16#${rip:0:2}))"
          elif [ "${rip:0:24}" = 0000000000000000FFFF0000 ]; then
            v4="${rip:24:8}"; ip="$((16#${v4:6:2})).$((16#${v4:4:2})).$((16#${v4:2:2})).$((16#${v4:0:2}))"
          else ip="ipv6"; fi
          case "$ip" in 127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;  # local
            *) conns="$conns $ip:$rport(uid $uid)" ;; esac ;;
    esac
  done <<EOF
$rows
EOF
done
kv listening "${listen# }"
kv outbound "${conns# }"
case "$conns" in *"(uid 0)"*) flag_risk "a root process (uid 0) has a live connection to the internet: find it before going on" ;; esac
[ -n "$adb_tcp" ] && [ "$(prop ro.adb.secure)" != 1 ] && \
  flag_review "adb is open on the network (port $adb_tcp) without key checks: anyone on the LAN can take root"
[ -n "$listen" ] && flag_review "listening on the network:$listen (uid 10000+ is an app; 'dumpsys package <pkg> | grep userId' maps them)"

# ---- online? and the clock ----
wifi="$(sh_ ls /sys/class/net | tr -s ' \t' '\n\n' | grep -E '^(wlan|wlp|eth)' | head -1)"
ip=""; [ -n "$wifi" ] && ip="$(sh_ "ip -4 addr show $wifi" | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)"
kv online "$([ -n "$ip" ] && echo "yes ($wifi)" || echo no)"
fd="$(sh_ 'date +%s')"; md="$(date +%s)"
if [ -n "$fd" ] && [ "$fd" -eq "$fd" ] 2>/dev/null; then
  skew=$(( (md - fd) / 86400 )); kv clock_days_behind "$skew"
  [ "${skew#-}" -gt 1 ] && flag_review "the frame's clock is $skew days off, so HTTPS fails until it gets network time"
fi
info=""
[ -n "$ip" ] || info=" the frame is offline, so live connections were not checked: rerun once it is on Wi-Fi (an isolated one, if an agent was found);"

if [ -n "$risk" ]; then verdict=risk; elif [ -n "$review" ]; then verdict=review; else verdict=clean; fi
kv security "$verdict"
kv notes "$(echo "${risk}${review}${info}" | sed 's/^ //')"
