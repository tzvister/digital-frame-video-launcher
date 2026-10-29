#!/bin/bash
# Give a frame a human name (people often have several, and their IPs keep changing).
#   scripts/set_name.sh -s <serial> "<name>"
# Stored on the frame (<storage>/.videoloop/name, shown in VideoLoop's menu title and
# Network info, and by find_frames.sh) and on the Mac (frames/<frame-id>/frame.env).
# Run again any time to rename.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

NAME="${ARGS[*]}"
NAME="$(printf '%s' "$NAME" | tr -d '\r\n' | sed 's/^ *//; s/ *$//')"
[ -n "$NAME" ] || die "give the frame a name, e.g. scripts/set_name.sh -s $SERIAL \"Living room\""
[ ${#NAME} -le 40 ] || die "keep the name to 40 characters or fewer"

P="$(primary)"
ID="$(frame_id)"
tmp="$(mktemp)"
printf '%s\n' "$NAME" > "$tmp"           # pushed as a file, so any characters survive
sh_ "mkdir -p $P/$DEVICE_DIR" >/dev/null
a push "$tmp" "$P/$DEVICE_DIR/name" >/dev/null 2>&1 || { rm -f "$tmp"; die "couldn't write the name to the frame"; }
rm -f "$tmp"

mkdir -p "$FRAMES_DIR/$ID"
{ echo "name=$NAME"; echo "named_at=$(date '+%Y-%m-%d %H:%M:%S')"; } > "$FRAMES_DIR/$ID/frame.env"

got="$(frame_name)"
[ "$got" = "$NAME" ] || die "the frame reports name '$got', expected '$NAME'"
echo "frame_name=$NAME"
echo "frame_id=$ID"
