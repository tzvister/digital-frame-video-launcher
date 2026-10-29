#!/bin/bash
# Raw backup of the frame's boot partitions over root adb, md5-checked against the frame.
#   scripts/backup.sh -s <serial> [partition ...]
# Default: whichever of the boot-chain partitions exist. Saved to frames/<id>/backup-<date>/.
# Needs root; without it, prints why and exits 0 (revert does not depend on this backup).
# Network adb on cheap frames can be ~0.1 MB/s: the defaults are small, "system" is not.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

ROOT_MODE="$(root_mode)"   # set here: as_root inside $(...) can't cache it for us
if [ "$ROOT_MODE" = none ]; then
  info "Skipped: raw partition backup needs root, and this frame has none. Revert does not depend on it."
  exit 0
fi

BYNAME=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name $(as_root "ls -d /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name"); do
  if [ -n "$(as_root "ls $d" | grep -v -i 'no such')" ]; then BYNAME="$d"; break; fi
done
[ -n "$BYNAME" ] || { info "Skipped: couldn't find the partition table (by-name links) on this frame."; exit 0; }

available="$(as_root "ls $BYNAME" | tr -s ' \t' '\n\n')"
if [ ${#ARGS[@]} -gt 0 ]; then
  PARTS="${ARGS[*]}"
else
  PARTS=""
  for p in bootloader uboot boot recovery env misc private frp media_data dtbo vbmeta; do
    echo "$available" | grep -qx "$p" && PARTS="$PARTS $p"
  done
fi
[ -n "$PARTS" ] || { info "Skipped: none of the boot-chain partitions were found in $BYNAME."; exit 0; }

OUT="$FRAMES_DIR/$(frame_id)/backup-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"
echo "Backup of [$PARTS ] from $SERIAL ($(prop ro.build.fingerprint)) $(date)" > "$OUT/MANIFEST.txt"
info "Backing up [$PARTS ] from $BYNAME into $OUT"

case "$ROOT_MODE" in adbd) DD="" ;; su) DD="su -c" ;; su0) DD="su 0 sh -c" ;; esac
fail=0
for P in $PARTS; do
  if [ -n "$DD" ]; then
    a exec-out "$DD 'dd if=$BYNAME/$P bs=1048576 2>/dev/null'" > "$OUT/$P.img"
  else
    a exec-out "dd if=$BYNAME/$P bs=1048576 2>/dev/null" > "$OUT/$P.img"
  fi
  dev="$(as_root "md5sum $BYNAME/$P" | awk '{print $1}')"
  mac="$(local_md5 "$OUT/$P.img")"
  if [ -n "$dev" ] && [ "$dev" = "$mac" ]; then r=PASS; else r=MISMATCH; fail=1; fi
  echo "$P.img $(local_size "$OUT/$P.img") bytes md5=$mac $r" | tee -a "$OUT/MANIFEST.txt"
done
[ "$fail" = 0 ] && info "Backup verified: $OUT" || warn "some partitions did not verify; see $OUT/MANIFEST.txt"
