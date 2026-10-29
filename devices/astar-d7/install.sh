#!/bin/bash
# Update VideoLoop on the original Allwinner astar-d7 frame. A thin wrapper: finds this
# frame model on the LAN, then runs the skill's install_app.sh (which needs the frame's
# snapshot from scripts/snapshot.sh). For any other frame, use the skill directly.
#   devices/astar-d7/install.sh [<ip>:5555] [--replace]
# Build first with ./build.sh.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
. "$DIR/find-frame.sh"

APK="$REPO/VideoLoop.apk"
[ -f "$APK" ] || { echo "No VideoLoop.apk yet. Run $REPO/build.sh first."; exit 1; }

D=""
case "$1" in *:*) D="$1"; shift ;; esac
if [ -z "$D" ]; then
  echo "Looking for the frame on the network ..."
  D="$(find_frame)" || { echo "Frame not found. Pass its address: $0 <ip>:5555 (frame menu -> Network info)"; exit 1; }
fi
echo "Using $D"
exec "$REPO/skills/digital-frame-launcher/scripts/install_app.sh" -s "$D" "$APK" "$@"
