#!/usr/bin/env python3
"""Run the explicit synthetic shared workflow on an emulator without an MCP tunnel."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared_server', ROOT / 'scripts/shared-server.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
PKG = 'com.ppomi.androidbridge'
SERVICE = PKG + '/.BridgeAccessibilityService'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    uuid.UUID(args.run_id)
    if not args.serial.startswith('emulator-'):
        raise SystemExit('This automatic fixture/permission test is emulator-only')
    adb = str(Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))) / 'platform-tools/adb')
    prefix = [adb, '-s', args.serial]

    def call(*arguments, binary=False):
        result = subprocess.run(prefix + list(arguments), capture_output=True, text=not binary, timeout=40)
        if result.returncode:
            raise RuntimeError('Emulator command failed')
        return result.stdout

    if call('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise SystemExit('Selected device is not an emulator')
    enabled = call('shell', 'settings', 'get', 'secure', 'enabled_accessibility_services').strip().split(':')
    if SERVICE not in enabled and PKG + '/' + PKG + '.BridgeAccessibilityService' not in enabled:
        raise SystemExit('Enable the emulator accessibility fixture before testing')
    others = [value for value in enabled if value not in ('', 'null', SERVICE, PKG + '/' + PKG + '.BridgeAccessibilityService')]
    forwards = [line.split() for line in call('forward', '--list').splitlines()]
    selected = [entry for entry in forwards if len(entry) == 3 and entry[0] == args.serial and entry[2] == 'tcp:8765']
    for _, local, _ in selected:
        call('forward', '--remove', local)
    process = None
    try:
        process = subprocess.Popen(prefix + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
            PKG + '.SharedWorkflowTest#testExplicitSharedFixtureRunAndServerCompletion', '-e', 'shared_run_id', args.run_id,
            PKG + '.test/android.test.InstrumentationTestRunner'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # Instrumentation restarts the app process. Rebind only this emulator's
        # already-enabled service, preserving unrelated accessibility services.
        time.sleep(2)
        call('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', ':'.join(others) or 'null')
        call('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', ':'.join(others + [SERVICE]))
        stdout, stderr = process.communicate(timeout=210)
        log = shared.PRIVATE / 'android-shared-workflow.txt'
        shared.private_write(log.with_suffix('.json'), {'stdout': stdout, 'stderr': stderr})
        if process.returncode or 'OK (1 test)' not in stdout or 'FAILURES' in stdout:
            raise RuntimeError('Shared workflow failed; inspect .ppomi/ssot/android-shared-workflow.json')
        proof = json.loads(call('exec-out', 'run-as', PKG, 'cat', 'files/shared-workflow-proof.json'))
        proof['mcpForwardRemovedDuringRun'] = True
        shared.private_write(shared.PRIVATE / 'android-shared-workflow-proof.json', proof)
        path = shared.PRIVATE / 'android-shared-workflow.png'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(call('exec-out', 'run-as', PKG, 'cat', 'files/shared-workflow-screen.png', binary=True))
        print(json.dumps(proof, ensure_ascii=False, indent=2))
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        for _, local, remote in selected:
            call('forward', local, remote)


if __name__ == '__main__':
    main()
