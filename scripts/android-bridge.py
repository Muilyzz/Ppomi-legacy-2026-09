#!/usr/bin/env python3
"""Pair the emulator companion and exercise its app-owned accessibility controls."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".ppomi/android-bridge.json"
SDK = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
ADB = SDK / "platform-tools/adb"
BRIDGE = "com.ppomi.androidbridge"
TARGET = "com.ppomi.androidtarget"
SERVICE = BRIDGE + "/.BridgeAccessibilityService"


def run(args, timeout=60, env=None):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        # am start contains provisioning secrets in its argument summary; do not echo command/output.
        raise RuntimeError("Android command failed: " + str(args[0]) + " (exit " + str(result.returncode) + ")")
    return result.stdout.decode("utf-8", errors="replace").strip()


def select_emulator():
    entries = [line.split() for line in run([ADB, "devices"]).splitlines()[1:] if line.strip()]
    ready = [parts[0] for parts in entries if len(parts) >= 2 and parts[0].startswith("emulator-") and parts[1] == "device"]
    selected = os.environ.get("PPOMI_ANDROID_SERIAL")
    if selected:
        if selected not in ready:
            raise RuntimeError("PPOMI_ANDROID_SERIAL must identify a running, authorized emulator.")
        return selected
    if len(ready) != 1:
        raise RuntimeError("Exactly one running emulator is required; set PPOMI_ANDROID_SERIAL to choose one. Physical phones are never selected.")
    return ready[0]


def adb(serial, *args):
    return run([ADB, "-s", serial, *args])


def load_config():
    config = json.loads(CONFIG.read_text())
    if not config["serial"].startswith("emulator-") or not 1024 <= config["port"] <= 65535:
        raise RuntimeError("Invalid emulator configuration")
    return config


def rpc(config, name, arguments=None, token=None):
    message = {"jsonrpc": "2.0", "id": secrets.token_hex(8), "method": "tools/call",
               "params": {"name": name, "arguments": arguments or {}}}
    request = urllib.request.Request("http://127.0.0.1:%d/mcp" % config["port"],
                                     data=json.dumps(message).encode(),
                                     headers={"Authorization": "Bearer " + (token or config["token"]),
                                              "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:
        body = json.load(response)
    if body.get("id") != message["id"]:
        raise RuntimeError("MCP response ID mismatch")
    if "error" in body:
        raise RuntimeError(str(body["error"]))
    result = body["result"]
    if result.get("isError"):
        raise RuntimeError(str(result.get("content")))
    return result.get("structuredContent") or json.loads(result["content"][0]["text"])


def prepare():
    run([ROOT / "scripts/android-emulator.sh", "boot"], timeout=150)
    serial = select_emulator()
    if adb(serial, "shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("This prototype only enables accessibility on an Android emulator.")
    bridge_apk = ROOT / "Android/app/build/outputs/apk/debug/app-debug.apk"
    target_apk = ROOT / "Android/controlfixture/build/outputs/apk/debug/controlfixture-debug.apk"
    if not bridge_apk.exists() or not target_apk.exists():
        env = dict(os.environ)
        env.setdefault("ANDROID_HOME", str(SDK))
        env.setdefault("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        run([ROOT / "Android/gradlew", "-p", ROOT / "Android", ":app:assembleDebug", ":controlfixture:assembleDebug"], timeout=300, env=env)
    # Keep the key stable so another MCP process is not invalidated every time a tab is opened.
    config = load_config() if CONFIG.exists() else {"port": 8765, "token": secrets.token_urlsafe(32), "serial": serial}
    previous_serial = config["serial"]
    config["serial"] = serial
    hashes = {package: hashlib.sha256(apk.read_bytes()).hexdigest() for package, apk in [(BRIDGE, bridge_apk), (TARGET, target_apk)]}
    installed = previous_serial == serial and config.get("apkHashes") == hashes
    try:
        installed = installed and all(adb(serial, "shell", "pm", "path", package).startswith("package:") for package in hashes)
    except RuntimeError:
        installed = False
    adb(serial, "forward", "tcp:%d" % config["port"], "tcp:8765")
    if installed:
        try:
            status = rpc(config, "status")
            if status.get("connected") and status.get("accessibilityEnabled"):
                print(json.dumps({"serial": serial, "status": status}, ensure_ascii=False))
                return config
        except (OSError, RuntimeError):
            pass
    else:
        for apk in [bridge_apk, target_apk]:
            adb(serial, "install", "-r", str(apk))
    config["apkHashes"] = hashes
    adb(serial, "shell", "am", "start", "-W", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-f", "0x14000000", "-n", BRIDGE + "/.DebugProvisioningActivity", "--es", "bridge_token", config["token"])
    services = adb(serial, "shell", "settings", "get", "secure", "enabled_accessibility_services")
    # A debug install or instrumentation run can leave the service marked crashed even
    # while its component stays enabled. Rebind only this emulator test service.
    full_service = BRIDGE + "/" + BRIDGE + ".BridgeAccessibilityService"
    enabled = [value for value in services.split(":") if value and value not in ("null", SERVICE, full_service)]
    adb(serial, "shell", "settings", "put", "secure", "enabled_accessibility_services", ":".join(enabled) or "null")
    time.sleep(0.2)
    enabled.append(SERVICE)
    adb(serial, "shell", "settings", "put", "secure", "enabled_accessibility_services", ":".join(enabled))
    adb(serial, "shell", "settings", "put", "secure", "accessibility_enabled", "1")
    adb(serial, "forward", "tcp:%d" % config["port"], "tcp:8765")
    CONFIG.parent.mkdir(exist_ok=True, mode=0o700)
    descriptor = os.open(CONFIG, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(config, output)
        output.write("\n")
    CONFIG.chmod(0o600)
    for attempt in range(30):
        try:
            status = rpc(config, "status")
            if not status.get("connected") or not status.get("accessibilityEnabled"):
                raise RuntimeError("Android AccessibilityService has not connected yet.")
            print(json.dumps({"serial": serial, "status": status}, ensure_ascii=False))
            return config
        except (OSError, RuntimeError):
            if attempt == 29:
                raise
            time.sleep(0.5)


def smoke(config):
    """No adb input commands: every tested action travels through the APK's MCP server."""
    checks = []

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)
        print("PASS: " + name, flush=True)

    try:
        rpc(config, "status", token="invalid-token")
        raise AssertionError("Unauthenticated request was accepted")
    except urllib.error.HTTPError as error:
        check(error.code in [401, 403], "unauthorized MCP client rejected")

    status = rpc(config, "status")
    print("Companion status:", json.dumps(status, ensure_ascii=False))
    rpc(config, "open_app", {"packageName": TARGET})
    time.sleep(0.6)

    expected_package = TARGET

    def tree():
        deadline = time.monotonic() + 10
        while True:
            try:
                result = rpc(config, "ui_tree")
                if result.get("packageName") == expected_package and len(result.get("nodes", [])) > 1:
                    return result
            except RuntimeError as error:
                if "No active accessibility window" not in str(error) and "Prototype permits only" not in str(error):
                    raise
            if time.monotonic() >= deadline:
                raise RuntimeError("Accessibility UI did not become ready for " + expected_package)
            time.sleep(0.2)

    def node(predicate):
        snapshot = tree()
        found = [item for item in snapshot["nodes"] if predicate(item)]
        if len(found) != 1:
            raise AssertionError("Expected one matching UI node, got %d" % len(found))
        return found[0]

    # The fixture has separate process/package ownership; this proves cross-app input.
    initial = tree()
    check(TARGET in json.dumps(initial), "UI tree read from separate target app")
    edit = node(lambda item: item.get("editable") is True)
    value = "뽀미 Android 한글 테스트 123"
    rpc(config, "type_text", {"nodeId": edit["id"], "text": value})
    time.sleep(0.2)
    check(value in json.dumps(tree(), ensure_ascii=False), "Korean text entered through AccessibilityService")
    # Fixture button lookup follows the view's exposed label rather than screen coordinates.
    submit = node(lambda item: item.get("text", "").casefold() == "apply text" and item.get("clickable") is True)
    old_id = submit["id"]
    rpc(config, "click", {"nodeId": old_id})
    time.sleep(0.3)
    check("Applied: " + value in json.dumps(tree(), ensure_ascii=False), "node click changed target app state")
    try:
        rpc(config, "click", {"nodeId": old_id})
        raise AssertionError("Stale node accepted")
    except RuntimeError as error:
        check("Stale nodeId" in str(error), "stale node rejected")
    counter = node(lambda item: re.fullmatch(r"Count: \d+", item.get("text", "")) is not None)
    previous_count = int(counter["text"].split(": ")[1])
    increment = node(lambda item: item.get("text", "").casefold() == "increment" and item.get("clickable") is True)
    bounds = increment["bounds"]
    if isinstance(bounds, dict):
        x = (bounds["left"] + bounds["right"]) / 2
        y = (bounds["top"] + bounds["bottom"]) / 2
    else:
        x, y = (bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2
    rpc(config, "tap", {"x": x, "y": y})
    time.sleep(0.3)
    check("Count: %d" % (previous_count + 1) in json.dumps(tree()), "dispatchGesture tap changed target counter")
    check(rpc(config, "status").get("lastGesture") == "completed", "Android confirmed gesture completion")
    rpc(config, "open_app", {"packageName": "com.android.settings"})
    expected_package = "com.android.settings"
    time.sleep(0.5)
    settings = tree()
    check("com.android.settings" in json.dumps(settings), "system Settings opened and inspected")
    width, height = settings["displayWidth"], settings["displayHeight"]
    rpc(config, "swipe", {"x1": width / 2, "y1": height * 0.8, "x2": width / 2, "y2": height * 0.3, "durationMs": 350})
    time.sleep(0.6)
    after = tree()
    check(rpc(config, "status").get("lastGesture") == "completed", "Android confirmed swipe completion")
    before_content = [(item["text"], item["bounds"]) for item in settings["nodes"]]
    after_content = [(item["text"], item["bounds"]) for item in after["nodes"]]
    check(before_content != after_content, "swipe changed Settings content or position")
    check(rpc(config, "back").get("performed") is True, "Android accepted Back navigation")
    time.sleep(0.3)
    check(rpc(config, "recents").get("performed") is True, "Android accepted Recents navigation")
    time.sleep(0.3)
    rpc(config, "home")
    deadline = time.monotonic() + 10
    while True:
        foreground = rpc(config, "status").get("foregroundPackage")
        if foreground and foreground not in [TARGET, BRIDGE, "com.android.settings"]:
            break
        if time.monotonic() >= deadline:
            raise AssertionError("Home navigation did not reach the selected launcher")
        time.sleep(0.2)
    home_status = rpc(config, "status")
    home_tree = rpc(config, "ui_tree")
    check(foreground in home_status.get("allowedPackages", []) and home_tree.get("packageName") == foreground,
          "selected default Home app is allowed and inspected")
    try:
        rpc(config, "open_app", {"packageName": "com.android.vending"})
        raise AssertionError("Disallowed package accepted")
    except RuntimeError as error:
        check("Prototype permits only" in str(error), "unlisted package rejected")
    rpc(config, "open_app", {"packageName": TARGET})
    result = {"serial": config["serial"], "checks": checks, "passed": len(checks), "transport": "APK MCP → AccessibilityService → separate app"}
    target = ROOT / ".ppomi/android-smoke-result.json"
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


def mac_smoke():
    """Exercise the shipped Mac stdio server, its proxy, and the Android companion together."""
    binary = Path(os.environ.get("PPOMI_TEST_BINARY") or ROOT / "Ppomi/.build/debug/Ppomi")
    env = {**os.environ, "PPOMI_DB": str(ROOT / ".ppomi/android-mcp-test.db")}
    process = subprocess.Popen([str(binary), "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=env)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    checks = []
    call_id = 0

    def request(method, params):
        nonlocal call_id
        call_id += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": call_id, "method": method, "params": params}).encode() + b"\n")
        process.stdin.flush()
        if not selector.select(timeout=25):
            raise RuntimeError("Mac MCP response timed out")
        reply = json.loads(process.stdout.readline())
        if reply.get("id") != call_id or "error" in reply:
            raise RuntimeError("Mac MCP response failed: " + str(reply.get("error")))
        return reply["result"]

    def call(name, args=None, expect_error=False):
        result = request("tools/call", {"name": name, "arguments": args or {}})
        if bool(result.get("isError")) != expect_error:
            raise AssertionError("Unexpected MCP error flag for " + name + ": " + str(result.get("content", [])[:1]))
        return result

    def payload(result):
        # android_screen appends a coordinate/capture note after the JSON object.
        text = next(item["text"] for item in result["content"] if item["type"] == "text")
        return json.JSONDecoder().raw_decode(text)[0]

    def screen():
        result = call("android_screen")
        image = next(item for item in result["content"] if item["type"] == "image")
        png = base64.b64decode(image["data"])
        assert png.startswith(b"\x89PNG\r\n\x1a\n")
        (ROOT / ".ppomi/android-mcp-screen.png").write_bytes(png)
        return payload(result)

    try:
        listed = request("tools/list", {})["tools"]
        assert len([item for item in listed if item["name"].startswith("android_")]) == 8
        checks.append("Mac MCP exposes all eight Android tools")
        assert payload(call("android_status"))["accessibilityEnabled"] is True
        checks.append("Mac MCP reaches paired Android AccessibilityService")
        call("android_open", {"packageName": TARGET})
        time.sleep(0.5)
        state = screen()
        edit = next(item for item in state["nodes"] if item.get("editable"))
        text = "뽀미 MCP에서 직접 입력 성공"
        call("android_type", {"nodeId": edit["id"], "text": text})
        time.sleep(0.2)
        state = screen()
        assert any(item.get("text") == text for item in state["nodes"])
        checks.append("Korean text verified through Mac MCP and Android app")
        button = next(item for item in state["nodes"] if item.get("text", "").casefold() == "apply text")
        call("android_click", {"nodeId": button["id"]})
        time.sleep(0.2)
        state = screen()
        assert any(item.get("text") == "Applied: " + text for item in state["nodes"])
        checks.append("Cross-app node click result and PNG returned through Mac MCP")
        call("android_click", {"nodeId": button["id"]}, expect_error=True)
        call("android_open", {"packageName": "com.android.vending"}, expect_error=True)
        checks.append("Control failures returned with MCP isError=true")
        print(json.dumps({"checks": checks, "passed": len(checks), "binary": str(binary)}, ensure_ascii=False, indent=2))
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "start", "status", "test", "test-mac"])
    args = parser.parse_args()
    if args.command in ["prepare", "start"]:
        config = prepare()
        if args.command == "start":
            env = {**os.environ, "PPOMI_ANDROID_SERIAL": config["serial"]}
            run([ROOT / "scripts/android-emulator.sh", "mirror"], env=env, timeout=150)
    elif args.command == "status":
        print(json.dumps(rpc(load_config(), "status"), ensure_ascii=False, indent=2))
    elif args.command == "test-mac":
        mac_smoke()
    else:
        smoke(load_config())


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
