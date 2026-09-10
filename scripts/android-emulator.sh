#!/bin/bash
# Local Android development target. Never selects a USB or network-connected phone.
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
command_name=${1:-mirror}
case "$command_name" in
    help|--help|-h)
        cat <<'USAGE'
Usage: scripts/android-emulator.sh [status|boot|mirror]
  status  Show SDK, Java, installed AVDs, and connected emulators.
  boot    Start an existing AVD and wait for Android to finish booting.
  mirror  Boot if needed and open one scrcpy window titled "Ppomi Android".

Optional: ANDROID_HOME / ANDROID_SDK_ROOT, JAVA_HOME,
          PPOMI_ANDROID_AVD (default Pixel_8_API_35),
          PPOMI_ANDROID_SERIAL (emulator-NNNN only), PPOMI_SCRCPY.
No command wipes an AVD, installs an APK, enables accessibility, or uses a phone.
USAGE
        exit 0 ;;
    status|boot|mirror) ;;
    *) fail "Unknown command: $command_name (use status, boot, or mirror)" ;;
esac
[[ $# -le 1 ]] || fail "Unexpected arguments. Use --help."

sdk=""
for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" && -x "$candidate/emulator/emulator" ]]; then
        sdk="$candidate"
        break
    fi
done
[[ -n "$sdk" ]] || fail "Android SDK with platform-tools and emulator not found. Set ANDROID_HOME."
adb="$sdk/platform-tools/adb"
emulator="$sdk/emulator/emulator"
export PATH="$sdk/platform-tools:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ -z "${JAVA_HOME:-}" && -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

serial=${PPOMI_ANDROID_SERIAL:-}
if [[ -n "$serial" ]]; then
    [[ "$serial" =~ ^emulator-[0-9]+$ ]] || fail "PPOMI_ANDROID_SERIAL must be an emulator serial; physical devices are disabled."
    port=${serial#emulator-}
    [[ "$port" =~ ^[1-9][0-9]{3}$ ]] || fail "Use a canonical emulator serial such as emulator-5554."
    (( port >= 5554 && port <= 5682 && port % 2 == 0 )) || fail "Emulator console port must be even and between 5554 and 5682."
fi

if [[ "$command_name" == status ]]; then
    printf 'sdk=%s\njava=%s\n' "$sdk" "${JAVA_HOME:-system default}"
    "$emulator" -list-avds
    "$adb" devices -l | awk 'NR == 1 || $1 ~ /^emulator-[0-9]+$/'
    exit 0
fi

# This lock is brief even when two UI clicks race to launch the same emulator.
cache="$HOME/Library/Caches/Ppomi/android"
mkdir -p "$cache"
chmod 700 "$cache"
lock="$cache/launch.lock"
if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -f "$lock/pid"
        rmdir "$lock" 2>/dev/null || true
        mkdir "$lock" 2>/dev/null || fail "Android launch is already running."
    else
        fail "Android launch is already running. Try again after it finishes."
    fi
fi
printf '%s\n' "$$" > "$lock/pid"
trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT

# A new process session survives a terminating caller/terminal. Use the Python 3
# development runtime already on PATH; report the missing prerequisite explicitly.
python=$(command -v python3 || true)
[[ -n "$python" ]] || fail "Python 3 is required to detach the emulator and mirror processes."
detach() {
    "$python" - "$@" <<'PY'
import subprocess, sys
with open(sys.argv[1], "ab", buffering=0) as log:
    process = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL,
                               stdout=log, stderr=log, start_new_session=True)
print(process.pid)
PY
}

scrcpy=""
if [[ "$command_name" == mirror ]]; then
    scrcpy=${PPOMI_SCRCPY:-$(command -v scrcpy || true)}
    [[ -n "$scrcpy" && -x "$scrcpy" ]] || fail "scrcpy is required for mirroring. Install it with: brew install scrcpy"
fi

devices=$("$adb" devices | awk '$1 ~ /^emulator-[0-9]+$/ {print $1}')
count=$(printf '%s\n' "$devices" | awk 'NF {n++} END {print n+0}')
if [[ -z "$serial" ]]; then
    (( count <= 1 )) || fail "Multiple emulators are running. Set PPOMI_ANDROID_SERIAL explicitly."
    if (( count == 1 )); then serial="$devices"; else serial=emulator-5554; fi
fi

if ! printf '%s\n' "$devices" | /usr/bin/grep -Fxq "$serial"; then
    avd=${PPOMI_ANDROID_AVD:-Pixel_8_API_35}
    "$emulator" -list-avds | /usr/bin/grep -Fxq "$avd" || fail "AVD '$avd' is not installed. Create it in Android Studio or set PPOMI_ANDROID_AVD."
    # Never ask the emulator to reopen an already running AVD under another serial.
    for device in $devices; do
        running_avd=$("$adb" -s "$device" emu avd name 2>/dev/null | head -n 1 | tr -d '\r' || true)
        [[ "$running_avd" != "$avd" ]] || fail "AVD '$avd' is already running as $device. Select that serial."
    done
    port=${serial#emulator-}
    emulator_pid=$(detach "$cache/emulator.log" "$emulator" -avd "$avd" -port "$port" -no-audio)
    printf 'Starting %s (%s, pid %s)\n' "$avd" "$serial" "$emulator_pid"
fi

deadline=$((SECONDS + 120))
while [[ $("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') != 1 ]]; do
    if [[ -n "${emulator_pid:-}" ]] && ! kill -0 "$emulator_pid" 2>/dev/null; then
        fail "Emulator exited during startup. See $cache/emulator.log"
    fi
    (( SECONDS < deadline )) || fail "Android boot timed out. See $cache/emulator.log"
    sleep 1
done
printf 'serial=%s\n' "$serial"
[[ "$command_name" == mirror ]] || exit 0

# Look at actual process arguments, so a stale/reused PID cannot suppress startup.
for pid in $(pgrep -x scrcpy || true); do
    process_command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$process_command" in
        *scrcpy\ --serial\ "$serial"\ --window-title\ Ppomi\ Android\ *)
            printf 'mirror=running\npid=%s\n' "$pid"
            exit 0 ;;
    esac
done
mirror_pid=$(detach "$cache/scrcpy.log" "$scrcpy" --serial "$serial" --window-title "Ppomi Android" --no-audio --max-size 1440 --window-width 360 --window-height 800)
sleep 2
kill -0 "$mirror_pid" 2>/dev/null || fail "scrcpy exited during startup. See $cache/scrcpy.log"
printf 'mirror=started\npid=%s\nlog=%s\n' "$mirror_pid" "$cache/scrcpy.log"
