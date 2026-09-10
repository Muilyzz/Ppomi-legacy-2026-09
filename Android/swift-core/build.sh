#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
target=${1:-android}
[[ "$target" == host || "$target" == android ]] || { echo 'Use build.sh host|android' >&2; exit 1; }
python3 "$here/stage.py"
if [[ "$target" == host ]]; then
    swift build --package-path "$here" --scratch-path "$here/build/host" --product accounting-core -c release
    exit 0
fi

toolchain=${PPOMI_SWIFT_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain}
swift="$toolchain/usr/bin/swift"
sdk_bundle=${PPOMI_SWIFT_ANDROID_SDK:-$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle/swift-android}
android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
ndk=${ANDROID_NDK_HOME:-$android_sdk/ndk/27.3.13750724}
[[ -x "$swift" && -d "$sdk_bundle/ndk-sysroot/usr/include" && -d "$ndk/toolchains/llvm/prebuilt" ]] || {
    echo 'Swift Android prerequisites are missing. Run Android/swift-core/setup.sh first.' >&2; exit 1;
}
ndk_tools=("$ndk"/toolchains/llvm/prebuilt/*/bin)
[[ ${#ndk_tools[@]} == 1 ]] || { echo 'Expected one Android NDK host toolchain.' >&2; exit 1; }
tools=${ndk_tools[0]}
triple=aarch64-unknown-linux-android28
bin="$here/build/android/$triple/release"
out="$here/build/jniLibs/arm64-v8a"
mkdir -p "$out"
"$swift" build --package-path "$here" --scratch-path "$here/build/android" --swift-sdk "$triple" -c release
cp "$bin/libppomi_accounting_core.so" "$out/"
"$tools/aarch64-linux-android28-clang" -shared -fPIC -O2 -Werror -Wall -Wextra \
    -Wl,-z,max-page-size=16384 -Wl,-soname,libppomi_accounting.so -Wl,--no-undefined \
    -Wl,-rpath,'$ORIGIN' "$here/jni/accounting_jni.c" -L"$out" -lppomi_accounting_core \
    -o "$out/libppomi_accounting.so"
"$tools/llvm-strip" --strip-debug "$out/libppomi_accounting_core.so" "$out/libppomi_accounting.so"
python3 "$here/package-runtime.py" "$tools/llvm-readelf" "$out" \
    "$sdk_bundle/swift-resources/usr/lib/swift-aarch64/android" \
    "${tools%/bin}/sysroot/usr/lib/aarch64-linux-android"
printf 'Android Swift/JNI libraries ready: %s\n' "$out"
