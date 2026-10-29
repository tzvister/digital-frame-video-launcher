#!/bin/bash
# Shared helpers for the digital-frame-launcher scripts (bash 3.2 compatible, macOS-first).
#   . "$(dirname "$0")/lib.sh"
# Scripts that act on a frame take its adb serial with -s (ip:5555 or a USB serial).

APP_PKG=videoloop.launcher
APP_MAIN=videoloop.launcher/.MainActivity
APP_HOME=videoloop.launcher/.HomeAlias
DEVICE_DIR=.videoloop                 # under the frame's primary storage
REPO_SLUG=tzvister/digital-frame-video-launcher

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# The skill normally lives inside the repo (skills/<name>); otherwise use ~/projects.
if [ -f "$SKILL_DIR/../../build.sh" ]; then
  REPO_DIR="${VIDEOLOOP_REPO:-$(cd "$SKILL_DIR/../.." && pwd -P)}"
else
  REPO_DIR="${VIDEOLOOP_REPO:-$HOME/projects/digital-frame-video-launcher}"
fi
FRAMES_DIR="${VIDEOLOOP_FRAMES:-$REPO_DIR/frames}"   # per-frame records, git-ignored

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "$*" >&2; }

# Reads -s SERIAL (or $ANDROID_SERIAL); everything else is left in ARGS.
parse_serial() {
  SERIAL="${ANDROID_SERIAL:-}"
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -s) SERIAL="$2"; shift 2 ;;
      *)  ARGS+=("$1"); shift ;;
    esac
  done
  [ -n "$SERIAL" ] || die "no frame given: pass -s <ip:5555 | usb-serial> (scripts/find_frames.sh lists them)"
}

a()    { adb -s "$SERIAL" "$@"; }
sh_()  { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
prop() { sh_ getprop "$1"; }

# Old adb shells don't pass the remote exit code back, so append and parse it.
#   run_ok "<cmd>"        as the adb shell user
#   run_ok "<cmd>" root   as root (see as_root)
run_ok() {
  local out
  if [ "$2" = root ]; then out="$(as_root "$1; echo __RC=\$?")" || return 1
  else out="$(sh_ "$1; echo __RC=\$?")"; fi
  echo "$out" | grep -v '^__RC=' | grep -v '^$' >&2
  echo "$out" | grep -q '^__RC=0$'
}

# Make sure adb can talk to the frame. Network links often go stale ("offline")
# after a reboot or Wi-Fi drop, so drop and reconnect them.
ensure_connected() {
  local st try
  for try in 1 2 3 4 5; do
    st="$(adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')"
    [ "$st" = "device" ] && return 0
    case "$SERIAL" in
      *:*) adb disconnect "$SERIAL" >/dev/null 2>&1; adb connect "$SERIAL" >/dev/null 2>&1 ;;
    esac
    sleep 2
  done
  st="$(adb devices | tr -d '\r' | awk -v s="$SERIAL" '$1==s{print $2}')"
  [ "$st" = "unauthorized" ] && die "$SERIAL is unauthorized: accept the 'Allow debugging' prompt on the frame's screen, then retry"
  die "can't reach $SERIAL over adb (state: ${st:-none}). Is the frame on, and on this network? Its IP may have changed: rerun scripts/find_frames.sh"
}

sdk() { prop ro.build.version.sdk; }

# Root: "adbd" (adb shell is already root), "su" / "su0" (an su binary works), or "none".
root_mode() {
  if sh_ id | grep -q 'uid=0('; then echo adbd
  elif sh_ "su -c id" | grep -q 'uid=0('; then echo su
  elif sh_ "su 0 id" | grep -q 'uid=0('; then echo su0
  else echo none; fi
}
ROOT_MODE=""
# Run a command as root. Keep the command free of single quotes.
as_root() {
  [ -n "$ROOT_MODE" ] || ROOT_MODE="$(root_mode)"
  case "$ROOT_MODE" in
    adbd) sh_ "$1" ;;
    su)   sh_ "su -c '$1'" ;;
    su0)  sh_ "su 0 sh -c '$1'" ;;
    *)    return 1 ;;
  esac
}

# The frame's own storage as the adb shell sees it (/sdcard, /storage/emulated/legacy, ...).
# (Old adb shells mix the frame's stderr into stdout, so test with output, not exit codes.)
primary() {
  local p
  if [ "$(sh_ '[ -d /sdcard ] && echo yes')" = yes ]; then echo /sdcard; return; fi
  p="$(sh_ 'echo $EXTERNAL_STORAGE')"
  echo "${p:-/sdcard}"
}

# Stable id for this frame (the Wi-Fi MAC may change every boot, so don't use it).
frame_id() {
  local id dev
  dev="$(prop ro.product.device)"
  id="$(sh_ settings get secure android_id)"
  case "$id" in ""|null|*rror*|*xception*) id="$(prop ro.serialno)" ;; esac
  case "$id" in ""|unknown|0123456789ABCDEF) id="$(prop ro.build.fingerprint | cksum | cut -d' ' -f1)" ;; esac
  echo "${dev}_${id}" | tr -c 'A-Za-z0-9_.\n-' '_'
}

# The activity that answers the HOME button right now.
current_home() {
  if [ "$(sdk)" -ge 24 ] 2>/dev/null; then
    sh_ "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
      | grep '/' | tail -1
  else
    sh_ "dumpsys activity activities" \
      | grep -oE 'cat=\[android\.intent\.category\.HOME\][^}]*cmp=[^ }]+' | head -1 | sed 's/.*cmp=//'
  fi
}

# All enabled HOME activities (Android 7+ only; empty on older versions).
home_candidates() {
  if [ "$(sdk)" -ge 24 ] 2>/dev/null; then
    sh_ "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
      | grep '/' | sort -u
  fi
}

is_videoloop() { case "$1" in "$APP_PKG"/*) return 0 ;; *) return 1 ;; esac; }

kv_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

local_md5() { if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | awk '{print $1}'; fi; }
dev_md5()   { sh_ "md5sum '$1'" | awk '{print $1}' | grep -E '^[0-9a-f]{32}$'; }
local_size() { wc -c < "$1" | tr -d ' '; }
