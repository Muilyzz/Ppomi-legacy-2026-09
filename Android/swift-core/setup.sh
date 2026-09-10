#!/bin/bash
# Install the version-matched official SDKs in the current user's development folders.
set -euo pipefail
swift_version=6.3.3
toolchain="$HOME/Library/Developer/Toolchains/swift-$swift_version-RELEASE.xctoolchain"
sdk="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-$swift_version-RELEASE_android.artifactbundle/swift-android"
android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
ndk="$android_sdk/ndk/27.3.13750724"
if [[ ! -x "$toolchain/usr/bin/swift" ]]; then
    if [[ ! -x "$HOME/.swiftly/bin/swiftly" ]]; then
        cache="$HOME/Library/Caches/Ppomi/swift-android"
        mkdir -p "$cache"
        curl -fL --retry 3 https://download.swift.org/swiftly/darwin/swiftly.pkg -o "$cache/swiftly.pkg"
        installer -pkg "$cache/swiftly.pkg" -target CurrentUserHomeDirectory
    fi
    if [[ ! -f "$HOME/.swiftly/config.json" ]]; then
        "$HOME/.swiftly/bin/swiftly" init --no-modify-profile --skip-install --quiet-shell-followup --assume-yes
    fi
    "$HOME/.swiftly/bin/swiftly" install "$swift_version" --assume-yes
fi
if [[ ! -f "$sdk/swift-sdk.json" ]]; then
    "$toolchain/usr/bin/swift" sdk install \
        https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
        --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5
fi
if [[ ! -f "$ndk/source.properties" ]]; then
    export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
    manager="$android_sdk/cmdline-tools/latest/bin/sdkmanager"
    [[ -x "$manager" ]] || { echo 'Install Android Studio command-line tools first.' >&2; exit 1; }
    "$manager" --sdk_root="$android_sdk" 'ndk;27.3.13750724'
fi
ANDROID_NDK_HOME="$ndk" "$sdk/scripts/setup-android-sdk.sh"
printf 'Swift %s + Android SDK + NDK r27d ready.\n' "$swift_version"
