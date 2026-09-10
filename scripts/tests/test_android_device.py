"""Host-side physical pairing boundaries; these tests never connect to a phone."""
import importlib.util
import base64
from contextlib import contextmanager
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import zlib

spec = importlib.util.spec_from_file_location("android_device", Path(__file__).resolve().parents[1] / "android-device.py")
device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device)
gesture_spec = importlib.util.spec_from_file_location("android_gesture", Path(__file__).resolve().parents[1] / "android-gesture-test.py")
gesture = importlib.util.module_from_spec(gesture_spec)
gesture_spec.loader.exec_module(gesture)


def screenshot_result():
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 3, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0\xff" * 2) * 3)) + chunk(b"IEND", b"")
    metadata = {"width": 2, "height": 3, "source": "android_accessibility",
                "packageName": "com.ppomi.androidtarget", "capturedAt": "2026-09-09T07:00:00Z",
                "screenshotId": "61974b7b-9c5e-4bfb-a19d-88d7b8f01d00"}
    return {"structuredContent": metadata, "content": [{"type": "image", "mimeType": "image/png",
                                                          "data": base64.b64encode(png).decode()}]}, png


@contextmanager
def local_mcp(redirect=False):
    hits = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            hits.append(self.path)
            self.send_response(500)
            self.end_headers()

        def do_POST(self):
            hits.append(self.path)
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if redirect:
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:%d/leak" % self.server.server_port)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps({"jsonrpc": "2.0", "id": payload["id"], "result": {
                "structuredContent": {"connected": True}, "content": []}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server.server_port, hits
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


class PhysicalDeviceTests(unittest.TestCase):
    def test_emulator_serial_rejected_without_adb(self):
        with patch.object(device, "devices") as discover:
            with self.assertRaisesRegex(RuntimeError, "physical phone"):
                device.require_physical("emulator-5554")
            discover.assert_not_called()

    def test_absent_phone_never_falls_back_to_emulator(self):
        with patch.object(device, "devices", return_value=[{"serial": "emulator-5554", "state": "device"}]), \
                patch.object(device, "adb") as adb:
            with self.assertRaisesRegex(RuntimeError, "absent"):
                device.require_physical("PHONE")
            adb.assert_not_called()

    def test_unauthorized_phone_never_runs_shell(self):
        with patch.object(device, "devices", return_value=[{"serial": "PHONE", "state": "unauthorized"}]), \
                patch.object(device, "adb") as adb:
            with self.assertRaisesRegex(RuntimeError, "unauthorized"):
                device.require_physical("PHONE")
            adb.assert_not_called()

    def test_emulator_hardware_rejected_under_other_serial(self):
        with patch.object(device, "devices", return_value=[{"serial": "localhost:5555", "state": "device"}]), \
                patch.object(device, "adb", side_effect=["1", "ranchu"]):
            with self.assertRaisesRegex(RuntimeError, "emulator"):
                device.require_physical("localhost:5555")

    def test_other_devices_forward_preserved(self):
        with patch.object(device, "forwards", return_value=[("OTHER", "tcp:8766", "tcp:8765")]), \
                patch.object(device, "adb") as adb:
            with self.assertRaisesRegex(RuntimeError, "preserved"):
                device.ensure_forward("PHONE", 8766)
            adb.assert_not_called()

    def test_exact_existing_forward_reused_without_mutation(self):
        with patch.object(device, "forwards", return_value=[("PHONE", "tcp:8766", "tcp:8765")]), \
                patch.object(device, "adb") as adb:
            self.assertEqual(device.ensure_forward("PHONE", 8766), 8766)
            adb.assert_not_called()

    def test_emulator_host_port_reserved(self):
        with patch.object(device, "forwards") as forwards:
            with self.assertRaisesRegex(RuntimeError, "8765"):
                device.ensure_forward("PHONE", 8765)
            forwards.assert_not_called()

    def test_atomic_pairing_file_private_and_serial_specific(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(device, "ROOT", Path(temporary)):
            first = {"kind": "physical", "serial": "PHONE", "port": 8766, "token": "a" * 43}
            path = device.save_config(first)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertNotIn("PHONE", path.name)
            self.assertEqual(device.load_config("PHONE"), first)
            self.assertIsNone(device.load_config("OTHER"))
            first["token"] = "b" * 43
            device.save_config(first)
            self.assertEqual(device.load_config("PHONE")["token"], "b" * 43)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_emulator_pairing_cannot_be_loaded_as_phone(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(device, "ROOT", Path(temporary)):
            path = device.config_path("PHONE")
            path.parent.mkdir()
            path.write_text(json.dumps({"serial": "PHONE", "port": 8765, "token": "a" * 43}))
            with self.assertRaisesRegex(RuntimeError, "emulator configuration"):
                device.load_config("PHONE")

    def test_rpc_refuses_wrong_transport_before_network(self):
        config = {"kind": "physical", "serial": "PHONE", "port": 8766, "token": "a" * 43}
        with patch.object(device, "forwards", return_value=[("OTHER", "tcp:8766", "tcp:8765")]), \
                patch.object(device.urllib.request, "build_opener") as build_opener:
            with self.assertRaisesRegex(RuntimeError, "exact ADB forward"):
                device.rpc(config, "status")
            build_opener.assert_not_called()

    def test_malformed_pairing_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(device, "ROOT", Path(temporary)):
            path = device.config_path("PHONE")
            path.parent.mkdir()
            for value in ([], {"kind": "physical", "serial": "PHONE", "port": 8766, "token": None}):
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(RuntimeError, "Invalid physical"):
                    device.load_config("PHONE")

    def test_native_png_saved_atomically_with_private_metadata(self):
        result, png = screenshot_result()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "screen.png"
            victim = Path(temporary) / "existing-file"
            victim.write_bytes(b"untouched")
            path.symlink_to(victim)
            summary = device.save_screen(result, path)
            self.assertEqual(path.read_bytes(), png)
            self.assertFalse(path.is_symlink())
            self.assertEqual(victim.read_bytes(), b"untouched")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual((summary["width"], summary["height"]), (2, 3))
            self.assertNotIn("data", summary)
            self.assertNotIn(result["content"][0]["data"], json.dumps(summary))

    def test_bad_png_and_metadata_never_replace_existing_output(self):
        valid, png = screenshot_result()
        variants = []
        mismatch = copy.deepcopy(valid)
        mismatch["structuredContent"]["width"] = 100
        variants.append(mismatch)
        checksum = copy.deepcopy(valid)
        checksum["content"][0]["data"] = base64.b64encode(png[:-1] + bytes([png[-1] ^ 1])).decode()
        variants.append(checksum)
        private_path = copy.deepcopy(valid)
        private_path["structuredContent"]["path"] = "/data/private"
        variants.append(private_path)
        duplicate = copy.deepcopy(valid)
        duplicate["content"].append(copy.deepcopy(duplicate["content"][0]))
        variants.append(duplicate)
        invalid_time = copy.deepcopy(valid)
        invalid_time["structuredContent"]["capturedAt"] = "2026-09-09T07:00:00"
        variants.append(invalid_time)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "screen.png"
            path.write_bytes(b"previous-proof")
            for result in variants:
                with self.assertRaises(RuntimeError):
                    device.save_screen(result, path)
                self.assertEqual(path.read_bytes(), b"previous-proof")

    def test_non_screen_output_rejected_before_device_access(self):
        with patch.object(sys, "argv", ["android-device.py", "call", "--serial", "PHONE",
                                      "--tool", "tap", "--output", "screen.png"]), \
                patch.object(sys, "stderr", io.StringIO()), patch.object(device, "require_physical") as physical:
            with self.assertRaises(SystemExit) as error:
                device.main()
            self.assertEqual(error.exception.code, 2)
            physical.assert_not_called()

    def test_gesture_client_refuses_rebound_forward_before_network(self):
        client = gesture.Client({"serial": "PHONE", "port": 8766, "token": "a" * 43})
        mappings = [SimpleNamespace(stdout="PHONE tcp:8766 tcp:8765\n"),
                    SimpleNamespace(stdout="OTHER tcp:8766 tcp:8765\n")]
        with patch.object(gesture.subprocess, "run", side_effect=mappings), \
                patch.object(gesture.urllib.request, "build_opener") as opener:
            client.require_forward()
            with self.assertRaisesRegex(RuntimeError, "explicit config serial"):
                client.call("tap", {"x": 1, "y": 1})
            opener.assert_not_called()

    def test_both_clients_refuse_http_redirects(self):
        with local_mcp(redirect=True) as (port, hits):
            config = {"serial": "PHONE", "port": port, "token": "a" * 43}
            with patch.object(device, "forwards", return_value=[("PHONE", "tcp:%d" % port, "tcp:8765")]), \
                    patch.object(gesture.subprocess, "run", return_value=SimpleNamespace(stdout="PHONE tcp:%d tcp:8765\n" % port)):
                with self.assertRaises(urllib.error.HTTPError) as first:
                    device.rpc(config, "status")
                with self.assertRaises(urllib.error.HTTPError) as second:
                    gesture.Client(config).call("status")
                self.assertEqual(first.exception.code, 302)
                self.assertEqual(second.exception.code, 302)
                first.exception.close()
                second.exception.close()
            self.assertEqual(hits, ["/mcp", "/mcp"])

    def test_both_clients_bypass_environment_proxy_and_raw_is_optional(self):
        with local_mcp() as (port, hits), local_mcp() as (proxy_port, proxy_hits):
            config = {"serial": "PHONE", "port": port, "token": "a" * 43}
            proxy = "http://127.0.0.1:%d" % proxy_port
            with patch.dict(os.environ, {"http_proxy": proxy, "HTTP_PROXY": proxy, "no_proxy": "", "NO_PROXY": ""}), \
                    patch.object(device.urllib.request, "proxy_bypass", return_value=False), \
                    patch.object(device, "forwards", return_value=[("PHONE", "tcp:%d" % port, "tcp:8765")]), \
                    patch.object(gesture.subprocess, "run", return_value=SimpleNamespace(stdout="PHONE tcp:%d tcp:8765\n" % port)):
                self.assertEqual(device.rpc(config, "status"), {"connected": True})
                self.assertEqual(device.rpc(config, "status", raw=True)["structuredContent"], {"connected": True})
                self.assertEqual(gesture.Client(config).call("status"), {"connected": True})
            self.assertEqual(hits, ["/mcp", "/mcp", "/mcp"])
            self.assertEqual(proxy_hits, [])


if __name__ == "__main__":
    unittest.main()
