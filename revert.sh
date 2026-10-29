#!/bin/bash
# Guaranteed revert: put the frame back on its original Frameo launcher.
# Works over network ADB with root. Run this from your Mac any time.
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
. "$PROJ/tools/find-frame.sh"

D="${1:-}"
if [ -z "$D" ]; then
  echo "Looking for the frame on the network ..."
  D="$(find_frame)" || { echo "Frame not found. Pass its address: ./revert.sh <ip>:5555 (shown in the frame's Network info menu)"; exit 1; }
fi
echo "Using $D"
adb connect "$D" >/dev/null 2>&1 || true

# Frameo's HOME component, recorded at deploy time.
FRAMEO_HOME=""
[ -f "$PROJ/frameo_home.txt" ] && FRAMEO_HOME="$(cat "$PROJ/frameo_home.txt")"

echo "Re-enabling Frameo ..."
if [ -n "$FRAMEO_HOME" ]; then
  adb -s "$D" shell "su -c 'pm enable $FRAMEO_HOME'" || true
fi
adb -s "$D" shell "su -c 'pm enable net.frameo.frame'" || true

echo "Disabling VideoLoop's home role ..."
adb -s "$D" shell "su -c 'pm disable videoloop.launcher/.HomeAlias'" || true

echo "Rebooting ..."
adb -s "$D" reboot
echo "Done. The frame will come back up in Frameo."
echo "(VideoLoop app stays installed; delete it with: adb -s $D uninstall videoloop.launcher)"
