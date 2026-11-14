#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
BUILD_DIR="$ANDROID_DIR/build"
SRC_DIR="$ANDROID_DIR/src/main"
APK_OUT="$ROOT_DIR/Numberblocks-Tablet.apk"

# Locate OpenJDK 17
if [[ -d "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
elif [[ -d "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" ]]; then
  export JAVA_HOME="/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
else
  export JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)"
fi
export PATH="$JAVA_HOME/bin:$PATH"

# Locate Android SDK
if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -d "/opt/homebrew/share/android-commandlinetools/build-tools/34.0.0" ]]; then
    ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
  else
    ANDROID_HOME="$HOME/Library/Android/sdk"
  fi
fi
BUILD_TOOLS="$ANDROID_HOME/build-tools/34.0.0"
PLATFORM_JAR="$ANDROID_HOME/platforms/android-34/android.jar"

if [[ ! -f "$PLATFORM_JAR" || ! -d "$BUILD_TOOLS" ]]; then
  echo "ERROR: Android SDK platform-34 or build-tools 34.0.0 not found in $ANDROID_HOME" >&2
  exit 1
fi

# Sync latest index.html into assets
mkdir -p "$SRC_DIR/assets"
cp "$ROOT_DIR/index.html" "$SRC_DIR/assets/index.html"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/compiled_res" "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

# 1. Compile resources with aapt2
"$BUILD_TOOLS/aapt2" compile --dir "$SRC_DIR/res" -o "$BUILD_DIR/res.zip"

# 2. Link resources + assets + AndroidManifest -> base.apk & R.java
"$BUILD_TOOLS/aapt2" link \
  -o "$BUILD_DIR/unaligned.apk" \
  -I "$PLATFORM_JAR" \
  --manifest "$SRC_DIR/AndroidManifest.xml" \
  -A "$SRC_DIR/assets" \
  --java "$BUILD_DIR/gen" \
  --min-sdk-version 21 \
  --target-sdk-version 34 \
  "$BUILD_DIR/res.zip"

# 3. Compile Java sources (targeting Java 8 bytecode for universal Android compatibility)
JAVA_FILES=()
while IFS= read -r -d '' f; do
  JAVA_FILES+=("$f")
done < <(find "$SRC_DIR/java" "$BUILD_DIR/gen" -name "*.java" -print0)

javac \
  -source 1.8 -target 1.8 \
  -bootclasspath "$PLATFORM_JAR" \
  -classpath "$PLATFORM_JAR" \
  -d "$BUILD_DIR/classes" \
  "${JAVA_FILES[@]}"

# 4. Convert .class -> classes.dex via d8
CLASS_FILES=()
while IFS= read -r -d '' f; do
  CLASS_FILES+=("$f")
done < <(find "$BUILD_DIR/classes" -name "*.class" -print0)

"$BUILD_TOOLS/d8" \
  --release \
  --min-api 21 \
  --lib "$PLATFORM_JAR" \
  --output "$BUILD_DIR/dex" \
  "${CLASS_FILES[@]}"

# 5. Add classes.dex into unaligned.apk
(cd "$BUILD_DIR/dex" && zip -q -j "$BUILD_DIR/unaligned.apk" classes.dex)

# 6. Align APK on 4-byte boundary
"$BUILD_TOOLS/zipalign" -f -p 4 "$BUILD_DIR/unaligned.apk" "$BUILD_DIR/aligned.apk"

# 7. Generate persistent debug/signing keystore if not present
KEYSTORE="$ANDROID_DIR/numberblocks-release.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair \
    -v \
    -keystore "$KEYSTORE" \
    -alias numberblocks \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass numberblocks123 \
    -keypass numberblocks123 \
    -dname "CN=Numberblocks Kids Game, OU=Education, O=Numberblocks, L=Hanoi, C=VN" >/dev/null 2>&1
fi

# 8. Sign APK (v1 + v2 + v3 signatures for Android 5..15+ tablets)
"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias numberblocks \
  --ks-pass pass:numberblocks123 \
  --key-pass pass:numberblocks123 \
  --out "$APK_OUT" \
  "$BUILD_DIR/aligned.apk"

echo "Built and signed: $APK_OUT"
ls -lh "$APK_OUT"
