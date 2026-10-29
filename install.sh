#!/bin/bash
# Install or upgrade VideoLoop.apk on the frame and relaunch it.
#   ./install.sh                 # finds the frame on the network
#   ./install.sh <ip>:5555       # or use a known address (frame menu -> Network info)
# Upgrades keep the app's settings and its HOME role. Build first with ./build.sh.
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
. "$PROJ/tools/find-frame.sh"

APK="$PROJ/VideoLoop.apk"
[ -f "$APK" ] || { echo "No VideoLoop.apk yet. Run ./build.sh first."; exit 1; }

D="${1:-}"
if [ -z "$D" ]; then
  echo "Looking for the frame on the network ..."
  D="$(find_frame)" || { echo "Frame not found. Pass its address: ./install.sh <ip>:5555"; exit 1; }
fi
echo "Using $D"
adb connect "$D" >/dev/null 2>&1 || true

adb -s "$D" install -r "$APK"
adb -s "$D" shell "am start -n videoloop.launcher/.MainActivity" >/dev/null
echo "Installed: $(adb -s "$D" shell dumpsys package videoloop.launcher | grep -m1 versionName | tr -d ' \r')"
