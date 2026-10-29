#!/bin/bash
# One-time Mac setup for ./build.sh: JDK 17 + Android SDK build-tools 34 + platform 34.
# No sudo needed (Homebrew formula/cask that just unpack).
set -e
echo "=== openjdk@17 ==="
brew install openjdk@17
echo "=== android-commandlinetools ==="
brew install --cask android-commandlinetools

export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
"$JAVA_HOME/bin/java" -version

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$ANDROID_HOME"
SDKMGR="$(command -v sdkmanager || echo /opt/homebrew/bin/sdkmanager)"

echo "=== accepting SDK licenses ==="
yes | "$SDKMGR" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
echo "=== platform-tools, build-tools;34.0.0, platforms;android-34 ==="
"$SDKMGR" --sdk_root="$ANDROID_HOME" "platform-tools" "build-tools;34.0.0" "platforms;android-34"

ls "$ANDROID_HOME/build-tools/34.0.0/aapt2" "$ANDROID_HOME/platforms/android-34/android.jar"
echo "Toolchain ready. Next: ./build.sh"
