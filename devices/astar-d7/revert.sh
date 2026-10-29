#!/bin/bash
# Put the original Allwinner astar-d7 frame back on its original home screen (Frameo).
# A thin wrapper: finds this frame model on the LAN, then runs the skill's revert.sh,
# which restores exactly what was recorded at install. It does not reboot.
#   devices/astar-d7/revert.sh [<ip>:5555] [--check | --uninstall | --clean | --restore-adb]
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
. "$DIR/find-frame.sh"

D=""
case "$1" in *:*) D="$1"; shift ;; esac
if [ -z "$D" ]; then
  echo "Looking for the frame on the network ..."
  D="$(find_frame)" || { echo "Frame not found. Pass its address: $0 <ip>:5555 (frame menu -> Network info)"; exit 1; }
fi
echo "Using $D"
exec "$REPO/skills/digital-frame-launcher/scripts/revert.sh" -s "$D" "$@"
