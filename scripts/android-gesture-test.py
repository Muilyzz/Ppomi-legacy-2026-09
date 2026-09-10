#!/usr/bin/env python3
"""Verify APK-owned gestures against the separate fixture using only authenticated MCP.

Requires an already installed fixture, enabled service, and host forwarding prepared
for the explicit config/serial. This script never installs, enables, or uses ADB input.
It opens and modifies only com.ppomi.androidtarget; it does not rearrange a launcher.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TARGET = "com.ppomi.androidtarget"
SDK = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
           or Path.home() / "Library/Android/sdk")
ADB = SDK / "platform-tools/adb"
MAX_RESPONSE_BYTES = 18 * 1024 * 1024


class ToolFailure(RuntimeError):
    pass


class Client:
    def __init__(self, config):
        if (not isinstance(config, dict)
                or not isinstance(config.get("serial"), str)
                or not re.fullmatch(r"[A-Za-z0-9_.:\[\]-]{1,200}", config["serial"])
                or type(config.get("port")) is not int or not 1024 <= config["port"] <= 65535
                or not isinstance(config.get("token"), str)
                or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", config["token"])):
            raise RuntimeError("Invalid explicit device MCP configuration")
        self.config = dict(config)

    def require_forward(self):
        try:
            response = subprocess.run([str(ADB), "forward", "--list"], capture_output=True,
                                      text=True, timeout=5, check=True)
        except (OSError, subprocess.SubprocessError):
            raise RuntimeError("Cannot verify the selected device's ADB forward; no MCP operation was sent") from None
        expected = (self.config["serial"], "tcp:%d" % self.config["port"], "tcp:8765")
        mappings = [tuple(line.split()) for line in response.stdout.splitlines() if len(line.split()) == 3]
        if expected not in mappings:
            raise RuntimeError("The active ADB forward does not match the explicit config serial; no MCP operation was sent")

    def call(self, name, arguments=None, raw=False):
        # Re-check on every call: a previously paired host port can be rebound later.
        self.require_forward()
        request_id = secrets.token_hex(8)
        body = {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                "params": {"name": name, "arguments": arguments or {}}}
        request = urllib.request.Request(
            "http://127.0.0.1:%d/mcp" % self.config["port"],
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": "Bearer " + self.config["token"],
                     "Content-Type": "application/json"})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, request, file_pointer, code, message, headers, new_url):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=15) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
        if len(payload) > MAX_RESPONSE_BYTES:
            raise RuntimeError("MCP response exceeds the local size limit")
        envelope = json.loads(payload)
        if not isinstance(envelope, dict) or envelope.get("id") != request_id or "error" in envelope:
            raise RuntimeError("Invalid MCP response envelope")
        result = envelope.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("MCP response has no tool result")
        if result.get("isError"):
            details = result.get("structuredContent", {})
            reason = details.get("error") if isinstance(details, dict) else None
            reason = reason if isinstance(reason, str) else "MCP tool rejected the request"
            raise ToolFailure(reason.replace(self.config["token"], "[redacted]")[:500])
        if raw:
            return result
        return result.get("structuredContent") or json.loads(result["content"][0]["text"])

    def tree(self):
        deadline = time.monotonic() + 8
        while True:
            try:
                value = self.call("ui_tree")
                if value.get("packageName") == TARGET and value.get("nodes"):
                    return value
            except ToolFailure as error:
                if "still active" in str(error):
                    raise
            if time.monotonic() >= deadline:
                raise RuntimeError("Fixture UI did not become ready")
            time.sleep(0.15)

    def finished(self, gesture_id):
        deadline = time.monotonic() + 10
        while True:
            value = self.call("gesture_status", {"gestureId": gesture_id})
            if value.get("id") != gesture_id:
                raise AssertionError("Gesture ID changed")
            if value.get("state") != "pending":
                return value
            if time.monotonic() >= deadline:
                # Completion is unknown. Do not issue another gesture or retry it.
                raise RuntimeError("Gesture completion is uncertain; inspect the device before any retry")
            time.sleep(0.08)


def node(snapshot, description):
    matches = [item for item in snapshot["nodes"]
               if item.get("contentDescription") == description and item.get("visible") and item.get("enabled")]
    if len(matches) != 1:
        raise AssertionError("Expected exactly one visible fixture node: " + description)
    return matches[0]


def center(item):
    bounds = item["bounds"]
    return ((bounds["left"] + bounds["right"]) / 2,
            (bounds["top"] + bounds["bottom"]) / 2)


def has_text(snapshot, text):
    return any(item.get("text") == text for item in snapshot["nodes"])


def private_write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
    path.chmod(0o600)


def run(args):
    config = json.loads(args.config.read_text())
    if config.get("serial") != args.serial:
        raise RuntimeError("Config serial does not match explicit --serial; no device operation was performed")
    port = config.get("port")
    if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
        raise RuntimeError("Invalid local MCP port")
    if not isinstance(config.get("token"), str) or not config["token"]:
        raise RuntimeError("Config has no bearer token")
    device_key = hashlib.sha256(args.serial.encode()).hexdigest()[:16]
    destination = ROOT / ".ppomi/android-gestures" / device_key
    report = {"deviceKey": device_key, "targetPackage": TARGET, "startedAt": time.time(),
              "transport": "authenticated_android_mcp", "checks": [], "gestures": [], "passed": False}
    client = Client(config)

    def check(condition, label):
        if not condition:
            raise AssertionError(label)
        report["checks"].append(label)
        print("PASS: " + label, flush=True)

    def rejected(name, arguments, expected, label):
        try:
            client.call(name, arguments)
        except ToolFailure as error:
            check(expected in str(error), label)
        else:
            raise AssertionError(label + ": unexpectedly accepted")

    def complete(accepted):
        check(accepted.get("accepted") is True and bool(accepted.get("gestureId")), "gesture accepted with stable ID")
        result = client.finished(accepted["gestureId"])
        report["gestures"].append(result)
        return result

    def start_node_gesture(tool, description, make_arguments):
        # Launch/keyboard accessibility events can invalidate a just-read tree.
        # Only this exact pre-dispatch rejection permits a fresh observation retry.
        for attempt in range(3):
            snapshot = client.tree()
            origin = node(snapshot, description)
            try:
                return client.call(tool, {"nodeId": origin["id"], **make_arguments(snapshot)}), origin
            except ToolFailure as error:
                if not str(error).startswith("Stale nodeId;") or attempt == 2:
                    raise
                time.sleep(0.2)

    try:
        status = client.call("status")
        check(status.get("connected") is True and status.get("accessibilityEnabled") is True,
              "MCP accessibility connection ready")
        check(status.get("emulator") is args.serial.startswith("emulator-"), "device category matches explicit serial")
        check(TARGET in status.get("allowedPackages", []), "separate fixture is allowlisted")
        client.call("open_app", {"packageName": TARGET})
        snapshot = client.tree()
        hold = node(snapshot, "long press target")
        check(hold.get("longClickable") is True, "fixture exposes a long-clickable target")
        accepted, hold = start_node_gesture("long_press", "long press target", lambda _: {"holdMs": 1200})
        # Attempt a harmless same-app launch while the pointer is held: it must not
        # supersede the active gesture. The long hold gives this check ample time.
        rejected("open_app", {"packageName": TARGET}, "still active", "concurrent foreground control is blocked")
        result = complete(accepted)
        check(result.get("state") == "completed", "long press input completed")
        snapshot = client.tree()
        check(has_text(snapshot, "Hold: completed"), "fixture observed an actual long press")
        rejected("long_press", {"nodeId": hold["id"]}, "Stale nodeId", "expired origin node is rejected")

        snapshot = client.tree()
        source = node(snapshot, "drag source")
        drop = node(snapshot, "drop target")
        x2, y2 = center(drop)
        rejected("long_press_drag", {"nodeId": source["id"], "x2": snapshot["displayWidth"], "y2": y2},
                 "within screen bounds", "out-of-bounds destination is rejected before touching")
        accepted, _ = start_node_gesture("long_press_drag", "drag source", lambda tree: {
            "x2": center(node(tree, "drop target"))[0], "y2": center(node(tree, "drop target"))[1],
            "holdMs": 900, "dragMs": 750, "hoverMs": 350})
        result = complete(accepted)
        check(result.get("state") == "completed", "continued hold-drag-release input completed")
        snapshot = client.tree()
        check(has_text(snapshot, "Drag: completed"), "fixture observed held pointer move into drop target")
        check(result.get("displayWidth") == snapshot["displayWidth"]
              and result.get("displayHeight") == snapshot["displayHeight"]
              and result.get("displayId") == 0, "gesture recorded its display geometry")

        # Capture completed output before the separate cancellation check changes it.
        if not args.skip_screen:
            image_result = client.call("screen", raw=True)
            blocks = [item for item in image_result.get("content", []) if item.get("type") == "image"]
            check(len(blocks) == 1 and blocks[0].get("mimeType") == "image/png", "native MCP screenshot returned one PNG")
            png = base64.b64decode(blocks[0]["data"], validate=True)
            check(len(png) >= 24 and png[:8] == b"\x89PNG\r\n\x1a\n", "screenshot contains actual PNG bytes")
            width, height = struct.unpack(">II", png[16:24])
            metadata = image_result.get("structuredContent", {})
            check((width, height) == (metadata.get("width"), metadata.get("height"))
                  and metadata.get("source") == "android_accessibility"
                  and metadata.get("packageName") == TARGET, "PNG dimensions and native source metadata agree")
            check("data" not in metadata and "path" not in metadata, "image bytes and private path are not duplicated in metadata")
            private_write(destination.with_suffix(".png"), png)
            report["screenshot"] = {**metadata, "file": str(destination.with_suffix(".png"))}

        snapshot = client.tree()
        source = node(snapshot, "drag source")
        x2, y2 = center(node(snapshot, "drop target"))
        accepted, _ = start_node_gesture("long_press_drag", "drag source", lambda tree: {
            "x2": center(node(tree, "drop target"))[0], "y2": center(node(tree, "drop target"))[1],
            "holdMs": 1500, "dragMs": 1200, "hoverMs": 500})
        cancel = client.call("cancel_gesture", {"gestureId": accepted["gestureId"]})
        check(cancel.get("cancelRequested") is True, "cancellation recorded for exact gesture ID")
        result = complete(accepted)
        check(result.get("state") == "cancelled" and result.get("outcomeNeedsVerification") is True,
              "cancelled gesture requires screen verification")
        snapshot = client.tree()
        check(not has_text(snapshot, "Drag: completed"), "cancelled drag did not reach the drop target")
        report["cancellationObservedText"] = [item["text"] for item in snapshot["nodes"]
                                              if item.get("text", "").startswith("Drag:")]
        # Observation only after cancellation: there is deliberately no automatic retry.
        check(client.call("gesture_status", {"gestureId": accepted["gestureId"]}).get("state") == "cancelled",
              "cancelled result remains stable without repeating the mutation")
        report["passed"] = True
    except Exception as error:
        report["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        report["finishedAt"] = time.time()
        private_write(destination.with_suffix(".json"), (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode())
        print("Proof: " + str(destination.with_suffix(".json")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--serial", required=True, help="Exact expected serial; must match the supplied config")
    parser.add_argument("--skip-screen", action="store_true", help="Skip native capture on Android versions before 11")
    run(parser.parse_args())
