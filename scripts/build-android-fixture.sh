#!/usr/bin/env bash
# Builds the Android fixture app with the SDK's own tools (no Gradle, no network) and prints the
# path of the signed .apk.
#
#   scripts/build-android-fixture.sh
#
# Needs the Android SDK (ANDROID_HOME, or ~/Library/Android/sdk on macOS and ~/Android/Sdk on
# Linux) with build tools and a platform,
# and a JDK. The app is signed with a debug key kept in .build/android-fixture.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname)" = Darwin ]; then default_sdk="$HOME/Library/Android/sdk"; else default_sdk="$HOME/Android/Sdk"; fi
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$default_sdk}}"
tools="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
platform="$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)"
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then JAVA_HOME="$(/usr/libexec/java_home)"; fi
java_home="${JAVA_HOME:?set JAVA_HOME to a JDK}"
source="$root/fixtures/android"
out="$root/.build/android-fixture"

mkdir -p "$out"
work="$(mktemp -d "$out/work.XXXXXX")"
trap 'rm -r "$work"' EXIT
mkdir -p "$work/gen" "$work/classes" "$work/dex"

"$tools/aapt2" compile --dir "$source/res" -o "$work/res.zip"
"$tools/aapt2" link -I "$platform/android.jar" --manifest "$source/AndroidManifest.xml" \
    --min-sdk-version 26 --target-sdk-version 34 --java "$work/gen" -o "$work/unsigned.apk" "$work/res.zip"
"$java_home/bin/javac" -nowarn --release 11 -classpath "$platform/android.jar" -d "$work/classes" \
    $(find "$source/src" "$work/gen" -name '*.java')
"$tools/d8" --min-api 26 --lib "$platform/android.jar" --output "$work/dex" $(find "$work/classes" -name '*.class')
(cd "$work/dex" && zip -q -u "$work/unsigned.apk" classes.dex)
"$tools/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"

keystore="$out/debug.keystore"
if [[ ! -f "$keystore" ]]; then
    "$java_home/bin/keytool" -genkeypair -keystore "$keystore" -storepass android -keypass android -alias fixture \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=macOS Harness fixture" >/dev/null 2>&1
fi
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
    --out "$out/HarnessFixture.apk" "$work/aligned.apk"
echo "$out/HarnessFixture.apk"
