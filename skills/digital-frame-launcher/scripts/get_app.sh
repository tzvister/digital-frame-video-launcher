#!/bin/bash
# Build VideoLoop.apk from the repo and print its path on the last line.
#   scripts/get_app.sh [--no-pull]
# Clones github.com/tzvister/digital-frame-video-launcher if it isn't on this Mac,
# fast-forwards it when clean, and refuses (with the fix) if the toolchain is missing.
. "$(dirname "$0")/lib.sh"

if [ ! -f "$REPO_DIR/build.sh" ]; then
  info "Cloning $REPO_SLUG into $REPO_DIR ..."
  if command -v gh >/dev/null; then gh repo clone "$REPO_SLUG" "$REPO_DIR" >&2 || die "clone failed (is gh logged in to an account with access?)"
  else git clone "https://github.com/$REPO_SLUG.git" "$REPO_DIR" >&2 || die "clone failed"; fi
elif [ "$1" != --no-pull ] && [ -d "$REPO_DIR/.git" ]; then
  if [ -z "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    git -C "$REPO_DIR" pull --ff-only -q >&2 || warn "couldn't update the repo; building the local copy"
  else
    warn "the repo has uncommitted changes; building them as they are"
  fi
fi

SDK_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JDK="${VIDEOLOOP_JAVA_HOME:-$(brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home}"
if [ ! -x "$SDK_HOME/build-tools/34.0.0/aapt2" ] || [ ! -f "$SDK_HOME/platforms/android-34/android.jar" ] \
   || [ ! -x "$JDK/bin/javac" ]; then
  die "the Android build toolchain is missing. With the user's OK, install it (Homebrew JDK 17 + Android SDK, ~1 GB, no sudo): $REPO_DIR/tools/setup-toolchain.sh"
fi

( cd "$REPO_DIR" && ./build.sh ) >&2 || die "build failed"
echo "$REPO_DIR/VideoLoop.apk"
