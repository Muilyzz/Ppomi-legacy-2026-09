#!/usr/bin/env python3
"""Real emulator UI test: Mac forwarding is removed while Android executes its own tasks."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SDK = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
ADB = str(SDK / "platform-tools/adb")
PKG = "com.ppomi.androidbridge"
SERVICE = PKG + "/.BridgeAccessibilityService"


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default=os.environ.get("PPOMI_ANDROID_SERIAL", "emulator-5554"))
    parser.add_argument("--skip-build", action="store_true")
    options = parser.parse_args()
    if not options.serial.startswith("emulator-"):
        raise SystemExit("Only an Android Emulator serial is accepted.")
    env = dict(os.environ, PPOMI_ANDROID_SERIAL=options.serial)
    run([ROOT / "scripts/android-emulator.sh", "boot"], env=env)
    adb = [ADB, "-s", options.serial]

    def read(*args):
        return run(adb + list(args), capture_output=True, text=True).stdout.strip()

    if read("shell", "getprop", "ro.kernel.qemu") != "1":
        raise SystemExit("Selected device is not an emulator.")
    if not options.skip_build:
        env.setdefault("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        env.setdefault("ANDROID_HOME", str(SDK))
        run([ROOT / "Android/gradlew", ":app:assembleDebug", ":app:assembleDebugAndroidTest", ":controlfixture:assembleDebug"], cwd=ROOT / "Android", env=env)
    for path in ["app/build/outputs/apk/debug/app-debug.apk", "controlfixture/build/outputs/apk/debug/controlfixture-debug.apk", "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"]:
        run(adb + ["install", "-r", ROOT / "Android" / path])

    def enable():
        entries = read("shell", "settings", "get", "secure", "enabled_accessibility_services")
        others = [v for v in entries.split(":") if v not in ("", "null", SERVICE, PKG + "/" + PKG + ".BridgeAccessibilityService")]
        # Rebind after force-stop while preserving every unrelated service.
        run(adb + ["shell", "settings", "put", "secure", "enabled_accessibility_services", ":".join(others) or "null"])
        run(adb + ["shell", "am", "start", "-W", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-f", "0x14000000", "-n", PKG + "/.MainActivity"])
        run(adb + ["shell", "settings", "put", "secure", "enabled_accessibility_services", ":".join(others + [SERVICE])])
        run(adb + ["shell", "settings", "put", "secure", "accessibility_enabled", "1"])

    # Remove this emulator's device MCP tunnels only. Restore exact prior mappings after all tests.
    forwards = [line.split() for line in read("forward", "--list").splitlines() if line.strip()]
    selected = [fields for fields in forwards if len(fields) == 3 and fields[0] == options.serial and fields[2] == "tcp:8765"]
    for _, local, _ in selected:
        run(adb + ["forward", "--remove", local])
    output = ROOT / ".ppomi/android-standalone"
    output.mkdir(parents=True, exist_ok=True)
    try:
        enable()
        for method in ["testStandaloneApprovalEvidenceAndCancel", "testPrepareProcessInterruption", "testVerifyProcessRecovery", "testHistoryEvidenceAndPackagedCore"]:
            if method == "testVerifyProcessRecovery":
                run(adb + ["shell", "am", "force-stop", PKG])
                enable()
            result = read("shell", "am", "instrument", "-w", "-r", "-e", "class",
                PKG + ".StandaloneWorkflowTest#" + method, PKG + ".test/android.test.InstrumentationTestRunner")
            (output / (method + ".txt")).write_text(result + "\n")
            print(result)
            if "OK (1 test)" not in result or "FAILURES" in result:
                raise RuntimeError("Instrumentation failed: " + method)
        result = read("shell", "am", "instrument", "-w", "-r", "-e", "class",
            PKG + ".LocalTaskPersistenceTest", PKG + ".test/android.test.InstrumentationTestRunner")
        (output / "persistence-tests.txt").write_text(result + "\n")
        if "OK (4 tests)" not in result or "FAILURES" in result:
            raise RuntimeError("Persistence/selection tests failed; see persistence-tests.txt")
        print("PASS: 4 persistence, selector and provider-address tests")
        for name in ["standalone-e2e.json", "standalone-recovery.json", "packaged-core-report.json", "workbench-record.png", "workbench-accounting.png"]:
            with (output / name).open("wb") as destination:
                run(adb + ["exec-out", "run-as", PKG, "cat", "files/" + name], stdout=destination)
        proof = json.loads((output / "standalone-e2e.json").read_text())
        with (output / "native-result.png").open("wb") as destination:
            run(adb + ["exec-out", "run-as", PKG, "cat", proof["completed"]["screenshotPath"]], stdout=destination)
        print("PASS: standalone request → approval → separate app → observed result → native evidence; cancellation and process recovery")
        print("Evidence:", output)
    finally:
        for _, local, remote in selected:
            run(adb + ["forward", local, remote])
        enable()


if __name__ == "__main__":
    main()
