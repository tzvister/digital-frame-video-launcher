#!/bin/bash
# Copy a video into the frame's VideoLoop folder and make VideoLoop play it.
#   scripts/set_video.sh -s <serial> <local-video> [--name <file-name-on-frame>] [--overwrite]
# Never replaces a different existing file unless --overwrite is given (the user's
# videos are theirs: only overwrite with their explicit OK). An identical file is reused.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

SRC="${ARGS[0]}"
NAME=""; OVERWRITE=no
i=1
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --name) NAME="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    --overwrite) OVERWRITE=yes; i=$((i+1)) ;;
    *) die "unknown option ${ARGS[$i]}" ;;
  esac
done
[ -f "$SRC" ] || die "video not found: $SRC"
[ -n "$NAME" ] || NAME="$(basename "$SRC")"
case "$NAME" in *"'"*|*/*) die "pick a file name without quotes or slashes (--name)" ;; esac

P="$(primary)"
DEST="$P/VideoLoop/$NAME"
want_md5="$(local_md5 "$SRC")"
want_size="$(local_size "$SRC")"

if [ "$(sh_ "[ -f '$DEST' ] && echo yes")" = yes ]; then
  have_md5="$(dev_md5 "$DEST")"
  have_size="$(sh_ "wc -c < '$DEST'" | tr -d ' ' | grep -E '^[0-9]+$')"
  same=no
  if [ -n "$have_md5" ]; then
    [ "$have_md5" = "$want_md5" ] && same=yes
  else
    [ "$have_size" = "$want_size" ] && same=yes     # no md5sum on very old frames
  fi
  if [ "$same" = yes ]; then
    info "Already on the frame (identical): $DEST"
  elif [ "$OVERWRITE" = yes ]; then
    info "Replacing $DEST (user approved overwrite)"
    a push "$SRC" "$DEST" >/dev/null 2>&1 || die "push failed"
  else
    die "a different file already exists at $DEST. Ask the user: overwrite it (--overwrite) or use another --name."
  fi
else
  sh_ "mkdir -p $P/VideoLoop" >/dev/null
  info "Copying $(basename "$SRC") ($want_size bytes) to $DEST ..."
  a push "$SRC" "$DEST" >/dev/null 2>&1 || die "push failed"
fi

got="$(dev_md5 "$DEST")"
if [ -n "$got" ] && [ "$got" != "$want_md5" ]; then die "copy on the frame doesn't match (md5 $got vs $want_md5)"; fi

# Ask the app to play it (and remember it as the chosen video).
a shell "am start -n $APP_MAIN -a $APP_PKG.PLAY --es path '$DEST'" >/dev/null 2>&1
echo "video_on_frame=$DEST"
echo "md5=${got:-unverified (no md5sum on the frame; size matched)}"
