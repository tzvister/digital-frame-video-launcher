#!/bin/bash
# Check that VideoLoop is the home screen, in front, playing, and looping.
#   scripts/verify.sh -s <serial> [--seconds N] [--min-events N]
# Watches the app's own log ("VideoLoop" tag) for N seconds (default 20) and counts
# play/loop events: at least --min-events (default 2) means the video is looping.
# Doesn't take screenshots: on some frames that stalls the video decoder.
. "$(dirname "$0")/lib.sh"
parse_serial "$@"
ensure_connected

SECS=20; MIN=2
i=0
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --seconds)    SECS="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    --min-events) MIN="${ARGS[$((i+1))]}";  i=$((i+2)) ;;
    *) die "unknown option ${ARGS[$i]}" ;;
  esac
done

fail=0
check() { if [ "$2" = ok ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

home="$(current_home)"
check "VideoLoop is the home screen ($home)" "$(is_videoloop "$home" && echo ok)"

front="$(sh_ dumpsys activity activities | grep -m1 -E 'mResumedActivity|ResumedActivity:' )"
echo "$front" | grep -q "$APP_PKG" && check "VideoLoop is in front" ok \
  || check "VideoLoop is in front (front: $(echo "$front" | grep -oE '[a-z0-9._]+/[A-Za-z0-9._$]+' | head -1))" no

awake="$(sh_ dumpsys power | grep -m1 -E 'mWakefulness=|Display Power: state=' )"
echo "$awake" | grep -qE 'Awake|ON' && check "screen is on" ok || check "screen is on ($awake)" no

a logcat -c >/dev/null 2>&1
info "Watching playback for ${SECS}s ..."
sleep "$SECS"
# One filterspec per tag: a later "VideoLoop:W" would override ":I" and hide the play lines.
log="$(a logcat -d -s VideoLoop:I 2>/dev/null | tr -d '\r')"
events="$(echo "$log" | grep -cE 'play /|loop \(native\)')"
playing="$(echo "$log" | grep -oE 'play /.*' | tail -1 | sed 's/^play //')"
[ -n "$playing" ] || playing="$(sh_ "cat /data/data/$APP_PKG/shared_prefs/videoloop.xml" | grep -oE '>[^<]+<' | head -1 | tr -d '<>')"
echo "$log" | grep -q 'no video to play' && check "a video is available to play" no
if [ "${events:-0}" -ge "$MIN" ]; then
  check "looping: $events play/loop events in ${SECS}s (${playing:-video})" ok
else
  check "looping: only ${events:-0} play/loop events in ${SECS}s (need $MIN; a clip longer than $((SECS / MIN))s needs a longer --seconds)" no
fi

[ "$fail" = 0 ] && echo "RESULT: all checks passed" || { echo "RESULT: some checks failed"; exit 1; }
