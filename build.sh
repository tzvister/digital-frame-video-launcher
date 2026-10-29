#!/bin/bash
# Build + sign VideoLoop.apk without Gradle.
set -e

# Toolchain from tools/setup-toolchain.sh; override with ANDROID_HOME / VIDEOLOOP_JAVA_HOME.
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${VIDEOLOOP_JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"

BT="$ANDROID_HOME/build-tools/34.0.0"
PLAT="$ANDROID_HOME/platforms/android-34/android.jar"
PROJ="$(cd "$(dirname "$0")" && pwd)"
OUT="$PROJ/build"

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/obj"

echo "=== 1. aapt2 link (manifest -> base.apk) ==="
"$BT/aapt2" link \
    -o "$OUT/base.apk" \
    -I "$PLAT" \
    --manifest "$PROJ/AndroidManifest.xml" \
    --java "$OUT/gen" \
    --min-sdk-version 19 \
    --target-sdk-version 28

echo "=== 2. javac ==="
RJAVA="$(find "$OUT/gen" -name R.java 2>/dev/null || true)"
"$JAVA_HOME/bin/javac" \
    -source 8 -target 8 \
    -bootclasspath "$PLAT" \
    -classpath "$PLAT" \
    -d "$OUT/obj" \
    $(find "$PROJ/src" -name '*.java') $RJAVA

echo "=== 3. d8 (dex) ==="
"$BT/d8" --min-api 19 --lib "$PLAT" --output "$OUT" $(find "$OUT/obj" -name '*.class')

echo "=== 4. add classes.dex to apk ==="
cp "$OUT/base.apk" "$OUT/app-unsigned.apk"
(cd "$OUT" && zip -q -j app-unsigned.apk classes.dex)

echo "=== 5. zipalign ==="
"$BT/zipalign" -f 4 "$OUT/app-unsigned.apk" "$OUT/app-aligned.apk"

echo "=== 6. sign ==="
KS="$PROJ/debug.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias videoloop \
    -storepass android -keypass android \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=VideoLoop,O=Frame,C=US"
fi
"$BT/apksigner" sign \
    --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --min-sdk-version 19 \
    --out "$PROJ/VideoLoop.apk" \
    "$OUT/app-aligned.apk"

echo "=== done ==="
"$BT/apksigner" verify --print-certs "$PROJ/VideoLoop.apk" >/dev/null && echo "signature OK"
ls -l "$PROJ/VideoLoop.apk"
