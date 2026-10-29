#!/bin/bash
# Pull the frame's partitions as raw images over root adb and md5-verify each one.
#   tools/backup-firmware.sh [ip:5555] [out-dir] [partition ...]
# Default partitions are the small boot chain. Add "system" for the 2 GB OS image,
# but expect hours: this frame's Wi-Fi only manages ~0.1 MB/s over adb.
# Partition names come from /dev/block/by-name on the frame. macOS (uses md5/stat -f).
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
. "$PROJ/tools/find-frame.sh"

D="${1:-}"
if [ -z "$D" ]; then
  echo "Looking for the frame on the network ..."
  D="$(find_frame)" || { echo "Frame not found. Pass its address as the first argument."; exit 1; }
fi
OUT="${2:-$PWD/frame-backup-$(date +%Y%m%d-%H%M)}"
shift $(( $# < 2 ? $# : 2 ))
PARTS="${*:-bootloader env boot recovery misc private frp media_data}"

adb connect "$D" >/dev/null 2>&1 || true
mkdir -p "$OUT"
cd "$OUT"
echo "Backing up [$PARTS] from $D into $OUT"
echo "Frame backup $(date)  device=$D  $(adb -s "$D" shell getprop ro.build.fingerprint | tr -d '\r')" >> MANIFEST.txt

for P in $PARTS; do
  adb -s "$D" exec-out "su -c 'dd if=/dev/block/by-name/$P bs=1048576 2>/dev/null'" > "$P.img"
  DEV=$(adb -s "$D" shell "su -c 'md5sum /dev/block/by-name/$P'" | awk '{print $1}')
  MAC=$(md5 -q "$P.img")
  if [ "$DEV" = "$MAC" ]; then R=PASS; else R=MISMATCH; fi
  echo "$P.img  $(stat -f%z "$P.img") bytes  md5=$MAC  $R" | tee -a MANIFEST.txt
done
