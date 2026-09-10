#!/usr/bin/env python3
"""Prepare an explicitly selected physical Android phone; never grant accessibility."""
import argparse
import base64
import binascii
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SDK = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
           or Path.home() / "Library/Android/sdk")
ADB = SDK / "platform-tools/adb"
BRIDGE = "com.ppomi.androidbridge"
TARGET = "com.ppomi.androidtarget"
SERVICE = BRIDGE + "/.BridgeAccessibilityService"
PHONE_PORT = 8765
MAX_PNG_BYTES = 12 * 1024 * 1024
MAX_RESPONSE_BYTES = 18 * 1024 * 1024


def run(args, timeout=60):
    try:
        result = subprocess.run([str(arg) for arg in args], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        # Intent arguments contain the provisioning token. Never echo the command.
        raise RuntimeError("Android command timed out; inspect the phone before retrying.") from None
    if result.returncode:
        raise RuntimeError("Android command failed (exit %d); no settings were bypassed." % result.returncode)
    return result.stdout.decode("utf-8", errors="replace").strip()


def adb(serial, *args, timeout=60):
    return run([ADB, "-s", serial, *args], timeout=timeout)


def devices():
    entries = []
    for line in run([ADB, "devices", "-l"]).splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2 or parts[0].startswith("*"):
            continue
        details = dict(value.split(":", 1) for value in parts[2:] if ":" in value)
        entries.append({"serial": parts[0], "state": parts[1],
                        "model": details.get("model"), "emulator": parts[0].startswith("emulator-")})
    return entries


def require_physical(serial):
    if not serial or serial.startswith("emulator-") or not re.fullmatch(r"[A-Za-z0-9_.:\[\]-]{1,200}", serial):
        raise RuntimeError("--serial must explicitly identify a physical phone; emulator fallback is disabled.")
    selected = next((entry for entry in devices() if entry["serial"] == serial), None)
    if selected is None:
        raise RuntimeError("The selected phone is absent from ADB. Unlock it, enable USB debugging, and accept this Mac's USB debugging dialog.")
    if selected["state"] != "device":
        raise RuntimeError("The selected phone is %s. Unlock it and accept the USB debugging dialog on the phone." % selected["state"])
    qemu = adb(serial, "shell", "getprop", "ro.kernel.qemu")
    hardware = adb(serial, "shell", "getprop", "ro.hardware")
    if qemu == "1" or hardware in ("ranchu", "goldfish"):
        raise RuntimeError("The selected transport is an emulator. Use android-bridge.py instead.")
    try:
        api = int(adb(serial, "shell", "getprop", "ro.build.version.sdk"))
    except ValueError:
        raise RuntimeError("The phone did not report a valid Android API level.") from None
    abis = adb(serial, "shell", "getprop", "ro.product.cpu.abilist").split(",")
    if api < 30 or "arm64-v8a" not in abis:
        raise RuntimeError("This physical-device build requires Android 11/API 30+ and arm64-v8a.")
    return {"serial": serial, "model": adb(serial, "shell", "getprop", "ro.product.model"),
            "apiLevel": api, "abis": abis, "emulator": False}


def config_path(serial):
    suffix = hashlib.sha256(serial.encode("utf-8")).hexdigest()[:16]
    return ROOT / (".ppomi/android-device-%s.json" % suffix)


def load_config(serial):
    path = config_path(serial)
    if not path.exists():
        return None
    value = json.loads(path.read_text())
    if (not isinstance(value, dict) or value.get("serial") != serial or value.get("kind") != "physical"
            or not isinstance(value.get("port"), int) or isinstance(value.get("port"), bool)
            or not 1024 <= value["port"] <= 65535 or value["port"] == 8765
            or not isinstance(value.get("token"), str)
            or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", value["token"])
            or not isinstance(value.get("apkHashes", {}), dict)):
        raise RuntimeError("Invalid physical phone pairing file; emulator configuration is never reused.")
    return value


def save_config(config):
    path = config_path(config["serial"])
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(config, output, ensure_ascii=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return path


def forwards():
    return [tuple(line.split()) for line in run([ADB, "forward", "--list"]).splitlines() if len(line.split()) == 3]


def ensure_forward(serial, preferred=None):
    if preferred is not None and (not 1024 <= preferred <= 65535 or preferred == 8765):
        raise RuntimeError("Choose a host port in 1024–65535 other than emulator port 8765.")
    existing = forwards()
    candidates = [preferred] if preferred is not None else range(8766, 8866)
    for port in candidates:
        local, remote = "tcp:%d" % port, "tcp:%d" % PHONE_PORT
        occupied = [item for item in existing if item[1] == local]
        if occupied:
            if occupied == [(serial, local, remote)]:
                return port
            if preferred is not None:
                raise RuntimeError("Requested host port already has another ADB forward; it was preserved.")
            continue
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                if preferred is not None:
                    raise RuntimeError("Requested host port is occupied; choose another --port.") from None
                continue
        # --no-rebind protects even against another ADB forward added after our check.
        adb(serial, "forward", "--no-rebind", local, remote)
        return port
    raise RuntimeError("No free phone port in 8766–8865; choose an explicit --port.")


def require_forward(config):
    expected = (config["serial"], "tcp:%d" % config["port"], "tcp:%d" % PHONE_PORT)
    if expected not in forwards():
        raise RuntimeError("This phone's exact ADB forward is absent. Run prepare again; existing mappings will be preserved.")


def rpc(config, name, arguments=None, raw=False):
    require_forward(config)
    message = {"jsonrpc": "2.0", "id": secrets.token_hex(8), "method": "tools/call",
               "params": {"name": name, "arguments": arguments or {}}}
    request = urllib.request.Request("http://127.0.0.1:%d/mcp" % config["port"],
                                     data=json.dumps(message).encode("utf-8"),
                                     headers={"Authorization": "Bearer " + config["token"],
                                              "Content-Type": "application/json"})
    # Localhost pairing must not be redirected or sent through a configured proxy.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, file_pointer, code, message, headers, new_url):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=20) as response:
        payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise RuntimeError("MCP response exceeds the local size limit.")
    body = json.loads(payload)
    if not isinstance(body, dict) or body.get("id") != message["id"] or "error" in body:
        raise RuntimeError("MCP request rejected or response ID did not match.")
    result = body.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("MCP response has no tool result.")
    if result.get("isError"):
        details = result.get("structuredContent")
        reason = details.get("error") if isinstance(details, dict) else None
        reason = reason if isinstance(reason, str) else "MCP tool returned an error"
        raise RuntimeError("Phone tool rejected the action: " + reason.replace(config["token"], "[redacted]")[:500])
    if raw:
        return result
    return result.get("structuredContent") or json.loads(result["content"][0]["text"])


def png_dimensions(png):
    if len(png) > MAX_PNG_BYTES or png[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("Screenshot is not a PNG within the 12 MB limit.")
    position, dimensions, saw_image, saw_end = 8, None, False, False
    while position + 12 <= len(png):
        length = struct.unpack(">I", png[position:position + 4])[0]
        end = position + 12 + length
        if end > len(png):
            raise RuntimeError("Screenshot PNG is truncated.")
        kind = png[position + 4:position + 8]
        chunk = png[position + 8:position + 8 + length]
        checksum = struct.unpack(">I", png[position + 8 + length:end])[0]
        if zlib.crc32(kind + chunk) & 0xFFFFFFFF != checksum:
            raise RuntimeError("Screenshot PNG checksum does not match.")
        if position == 8 and (kind != b"IHDR" or length != 13):
            raise RuntimeError("Screenshot PNG has no valid header.")
        if kind == b"IHDR":
            if dimensions is not None or length != 13:
                raise RuntimeError("Screenshot PNG has an invalid header.")
            dimensions = struct.unpack(">II", chunk[:8])
            width, height = dimensions
            if not (0 < width <= 16384 and 0 < height <= 16384 and width * height <= 64 * 1024 * 1024):
                raise RuntimeError("Screenshot dimensions exceed the supported display bounds.")
        elif kind == b"IDAT":
            saw_image = True
        elif kind == b"IEND":
            if length != 0 or end != len(png):
                raise RuntimeError("Screenshot PNG has invalid trailing data.")
            saw_end = True
            break
        position = end
    if dimensions is None or not saw_image or not saw_end:
        raise RuntimeError("Screenshot PNG is incomplete.")
    return dimensions


def save_screen(result, path):
    """Validate a native MCP PNG, then save privately without printing its payload."""
    path = Path(path).absolute()
    if path.suffix.lower() != ".png":
        raise RuntimeError("--output must name a .png file.")
    if not isinstance(result, dict) or result.get("isError"):
        raise RuntimeError("Cannot save an unsuccessful screenshot result.")
    content = result.get("content", [])
    if not isinstance(content, list):
        raise RuntimeError("Screenshot content must be an MCP content list.")
    images = [item for item in content if isinstance(item, dict) and item.get("type") == "image"]
    if len(images) != 1 or images[0].get("mimeType") != "image/png":
        raise RuntimeError("Native screenshot must return exactly one PNG image.")
    encoded = images[0].get("data")
    if not isinstance(encoded, str) or len(encoded) > 4 * ((MAX_PNG_BYTES + 2) // 3):
        raise RuntimeError("Screenshot image data exceeds the local size limit.")
    try:
        png = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise RuntimeError("Screenshot contains invalid base64 image data.") from None
    width, height = png_dimensions(png)
    metadata = result.get("structuredContent")
    if (not isinstance(metadata, dict)
            or type(metadata.get("width")) is not int or type(metadata.get("height")) is not int
            or (metadata["width"], metadata["height"]) != (width, height)
            or metadata.get("source") != "android_accessibility"
            or not isinstance(metadata.get("packageName"), str)
            or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+", metadata["packageName"])
            or "data" in metadata or "path" in metadata):
        raise RuntimeError("Screenshot dimensions or native source metadata do not match.")
    try:
        captured_at = datetime.fromisoformat(metadata["capturedAt"].replace("Z", "+00:00"))
        if captured_at.tzinfo is None:
            raise ValueError("Missing timezone")
        screenshot_id = str(uuid.UUID(metadata["screenshotId"]))
    except (KeyError, AttributeError, TypeError, ValueError):
        raise RuntimeError("Screenshot is missing valid capture time or screenshot ID.") from None
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(png)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"file": str(path), "width": width, "height": height,
            "source": metadata["source"], "packageName": metadata["packageName"],
            "capturedAt": captured_at.isoformat(), "screenshotId": screenshot_id,
            "sha256": hashlib.sha256(png).hexdigest()}


def accessibility_enabled(serial):
    value = adb(serial, "shell", "settings", "get", "secure", "enabled_accessibility_services")
    return any(item in (SERVICE, BRIDGE + "/" + BRIDGE + ".BridgeAccessibilityService")
               for item in value.split(":"))


def inspect_apk(apk, package, require_swift=False):
    if not apk.is_file():
        raise RuntimeError("Build the debug APK first: " + str(apk))
    candidates = sorted((SDK / "build-tools").glob("*/aapt2"), reverse=True)
    if not candidates:
        raise RuntimeError("Android SDK build-tools/aapt2 is required to validate the APK.")
    badging = run([candidates[0], "dump", "badging", apk])
    if not badging.startswith("package: name='%s' " % package) or "\napplication-debuggable\n" not in badging:
        raise RuntimeError("Expected the Ppomi debug APK with matching package identity.")
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if require_swift and not any(name.startswith("lib/arm64-v8a/") and name.endswith(".so") for name in names):
            raise RuntimeError("The APK is missing arm64 native libraries.")
    return hashlib.sha256(apk.read_bytes()).hexdigest()


def status(serial, info=None):
    info = info or require_physical(serial)
    result = dict(info, accessibilityEnabled=accessibility_enabled(serial))
    config = load_config(serial)
    if config is not None:
        result.update(configFile=str(config_path(serial)), hostPort=config["port"])
        try:
            result["bridge"] = rpc(config, "status")
        except (OSError, ValueError, RuntimeError):
            result["bridge"] = {"connected": False}
    else:
        result["bridge"] = {"connected": False, "paired": False}
    if not result["accessibilityEnabled"]:
        result["nextStep"] = "폰의 뽀미 설정에서 접근성 설정을 열고 뽀미 서비스를 직접 켜세요. 권한은 자동으로 부여하지 않습니다."
    elif not result["bridge"].get("connected"):
        result["nextStep"] = "폰에서 뽀미를 열고 설정 화면의 접근성 연결 상태를 확인하세요. 연결 후 status를 다시 실행하세요."
    return result


def prepare(serial, port=None, with_fixture=False):
    info = require_physical(serial)
    apks = [(BRIDGE, ROOT / "Android/app/build/outputs/apk/debug/app-debug.apk")]
    if with_fixture:
        apks.append((TARGET, ROOT / "Android/controlfixture/build/outputs/apk/debug/controlfixture-debug.apk"))
    hashes = {package: inspect_apk(apk, package, require_swift=package == BRIDGE) for package, apk in apks}
    config = load_config(serial) or {"kind": "physical", "serial": serial, "token": secrets.token_urlsafe(32)}
    selected_port = port if port is not None else config.get("port")
    config["port"] = ensure_forward(serial, selected_port)
    # Save the stable credential before provisioning, so an interrupted run can recover.
    save_config(config)
    installed_hashes = config.setdefault("apkHashes", {})
    for package, apk in apks:
        # Package lookup can return a nonzero code for an app that is not installed.
        try:
            already_installed = adb(serial, "shell", "pm", "path", package).startswith("package:")
        except RuntimeError:
            already_installed = False
        if not already_installed or installed_hashes.get(package) != hashes[package]:
            adb(serial, "install", "-r", apk, timeout=180)
            installed_hashes[package] = hashes[package]
            save_config(config)
    adb(serial, "shell", "am", "start", "-W", "-a", "android.intent.action.MAIN",
        "-c", "android.intent.category.LAUNCHER", "-f", "0x14000000",
        "-n", BRIDGE + "/.DebugProvisioningActivity", "--es", "bridge_token", config["token"])
    return status(serial, info)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("devices", "prepare", "status", "call"))
    parser.add_argument("--serial", help="Exact ADB serial of the authorized physical phone")
    parser.add_argument("--port", type=int, help="prepare: dedicated Mac localhost port; 8765 is reserved for the emulator")
    parser.add_argument("--with-fixture", action="store_true", help="prepare: also install the separate reversible test app")
    parser.add_argument("--tool", help="call: explicit MCP tool name")
    parser.add_argument("--arguments", default="{}", help="call: MCP arguments JSON object")
    parser.add_argument("--output", type=Path, help="call --tool screen: validate and privately save the native PNG")
    args = parser.parse_args()
    if args.output is not None and (args.command != "call" or args.tool != "screen"):
        parser.error("--output is only valid with call --tool screen")
    if args.output is not None and args.output.suffix.lower() != ".png":
        parser.error("--output must name a .png file")
    if args.command == "devices":
        if args.port or args.with_fixture or args.tool:
            parser.error("devices only lists ADB transports")
        result = {"devices": devices()}
    else:
        if not args.serial:
            parser.error("--serial is required; no phone or emulator is selected automatically")
        if args.command != "prepare" and (args.port is not None or args.with_fixture):
            parser.error("--port and --with-fixture are prepare options")
        if args.command == "prepare":
            result = prepare(args.serial, args.port, args.with_fixture)
        elif args.command == "status":
            result = status(args.serial)
        else:
            require_physical(args.serial)
            if not args.tool:
                parser.error("call requires --tool")
            arguments = json.loads(args.arguments)
            if not isinstance(arguments, dict):
                parser.error("--arguments must be a JSON object")
            config = load_config(args.serial)
            if config is None:
                raise RuntimeError("Run prepare for this exact phone before calling its MCP tools.")
            result = rpc(config, args.tool, arguments, raw=args.output is not None)
            if args.output is not None:
                result = save_screen(result, args.output)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
