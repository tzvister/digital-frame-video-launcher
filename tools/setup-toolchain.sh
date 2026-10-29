#!/bin/bash
# One-time Mac setup for ./build.sh and the frame scripts: adb, JDK 17, Android SDK 34.
# Works on Apple Silicon and Intel Macs. Needs Homebrew; no sudo (formula/casks that
# just unpack). About 1 GB of downloads.
set -e
command -v brew >/dev/null || {
  echo "Homebrew is required. Install it from https://brew.sh (one command), then rerun this." >&2
  exit 1
}

echo "=== adb (android-platform-tools) ==="
command -v adb >/dev/null || brew install --cask android-platform-tools
echo "=== openjdk@17 ==="
brew install openjdk@17
echo "=== android-commandlinetools ==="
brew install --cask android-commandlinetools

export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
"$JAVA_HOME/bin/java" -version

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$ANDROID_HOME"
SDKMGR="$(command -v sdkmanager || echo "$(brew --prefix)/bin/sdkmanager")"

echo "=== accepting SDK licenses ==="
yes | "$SDKMGR" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
echo "=== build-tools;34.0.0, platforms;android-34 ==="
"$SDKMGR" --sdk_root="$ANDROID_HOME" "build-tools;34.0.0" "platforms;android-34"

ls "$ANDROID_HOME/build-tools/34.0.0/aapt2" "$ANDROID_HOME/platforms/android-34/android.jar"
echo "Toolchain ready. Next: ./build.sh"
