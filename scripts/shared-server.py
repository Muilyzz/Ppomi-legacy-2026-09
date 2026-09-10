#!/usr/bin/env python3
"""Explicit, device-scoped Supabase provisioning. Requires an already linked CLI.

Admin credentials are read from the logged-in CLI into memory only. Device
passwords are written to ignored, owner-only files for Keychain/Keystore import.
No existing local records are uploaded. Never run this script with shell tracing.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / '.ppomi' / 'ssot'


class SafeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise SafeError('Redirect refused')


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.shared-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def private_read(path):
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise SafeError('Configuration must be a private regular file')
    return json.loads(path.read_text())


def http(url, key, path, body, token=None):
    if not re.fullmatch(r'https://[a-z0-9]{1,63}\.supabase\.co', url):
        raise SafeError('Invalid Supabase HTTPS endpoint')
    request = urllib.request.Request(url + path, data=json.dumps(body).encode(),
        headers={'apikey': key, 'Content-Type': 'application/json',
                 **({'Authorization': 'Bearer ' + token} if token else {})})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise SafeError('Server response exceeded size limit')
        return json.loads(data)
    except urllib.error.HTTPError as error:
        # Do not print remote bodies: auth errors may contain credential values.
        raise SafeError('Supabase request failed: HTTP ' + str(error.code)) from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise SafeError('Supabase connection or response failed') from None


def login(config):
    return http(config['url'], config['publishableKey'], '/auth/v1/token?grant_type=password',
                {'email': config['email'], 'password': config['password']})


def rpc(config, name, params):
    if not re.fullmatch(r'ppomi_[a-z_]+', name):
        raise SafeError('Only ppomi RPC functions are accepted')
    session = login(config)
    return http(config['url'], config['publishableKey'], '/rest/v1/rpc/' + name,
                params, session['access_token'])


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def query(sql):
    fd, path = tempfile.mkstemp(prefix='ppomi-shared-', suffix='.sql', dir=PRIVATE)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(sql)
        result = subprocess.run(['supabase', 'db', 'query', '--linked', '--file', path, '--output', 'json'],
                                cwd=ROOT, capture_output=True, text=True)
        if result.returncode:
            raise SafeError('Linked database provisioning query failed; inspect schema before retrying')
        return json.loads(result.stdout)
    finally:
        os.unlink(path)


def bootstrap(project):
    if not re.fullmatch(r'[a-z]{20}', project):
        raise SafeError('Invalid project ref')
    linked = ROOT / 'supabase' / '.temp' / 'project-ref'
    if not linked.exists() or linked.read_text().strip() != project:
        raise SafeError('Supabase CLI must be linked to the requested project first')
    PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(PRIVATE, 0o700)
    result = subprocess.run(['supabase', 'projects', 'api-keys', '--project-ref', project,
                             '--reveal', '--output', 'json'], capture_output=True, text=True, cwd=ROOT)
    if result.returncode:
        raise SafeError('Logged-in Supabase CLI could not read project API keys')
    keys = json.loads(result.stdout)
    public = next((item['api_key'] for item in keys if item.get('type') == 'publishable'), None)
    admin = next((item['api_key'] for item in keys if item.get('name') == 'service_role'), None)
    if not public or not admin:
        raise SafeError('Project publishable/admin API keys unavailable')
    url = 'https://' + project + '.supabase.co'
    manifest_path = PRIVATE / 'devices.json'
    manifest = private_read(manifest_path) if manifest_path.exists() else {
        'projectRef': project, 'workspaceId': str(uuid.uuid4()), 'devices': {}}
    if manifest['projectRef'] != project:
        raise SafeError('Existing private configuration belongs to another project')
    private_write(manifest_path, manifest)
    for name, label, platform in [('mac', '뽀미 Mac', 'macos'),
                                  ('emulator', '뽀미 Android 에뮬레이터', 'android'),
                                  ('fold', '뽀미 Galaxy Fold', 'android')]:
        config_path = PRIVATE / (name + '.json')
        if config_path.exists():
            config = private_read(config_path)
            if config['url'] != url:
                raise SafeError('Existing device belongs to another project')
        else:
            config = {'url': url, 'publishableKey': public,
                      'email': 'device-' + uuid.uuid4().hex + '@devices.ppomi.invalid',
                      'password': secrets.token_urlsafe(36), 'deviceId': str(uuid.uuid4())}
            private_write(config_path, config)
        if name not in manifest['devices']:
            try:
                session = login(config)
                user_id = session['user']['id']
            except SafeError:
                user = http(url, admin, '/auth/v1/admin/users',
                    {'email': config['email'], 'password': config['password'], 'email_confirm': True}, admin)
                user_id = user['id']
            manifest['devices'][name] = {'id': config['deviceId'], 'authUserId': user_id,
                                         'label': label, 'platform': platform}
            private_write(manifest_path, manifest)
        else:
            session = login(config)
            if session['user']['id'] != manifest['devices'][name]['authUserId']:
                raise SafeError('Existing device authentication mismatch')
    workspace = str(uuid.UUID(manifest['workspaceId']))
    statements = ['begin;', 'insert into public.ppomi_workspaces(id,name) values (' +
                  sql_string(workspace) + ", '뽀미') on conflict (id) do nothing;"]
    for device in manifest['devices'].values():
        values = [str(uuid.UUID(device['id'])), workspace, str(uuid.UUID(device['authUserId'])),
                  device['label'], device['platform']]
        statements.append('insert into public.ppomi_devices(id,workspace_id,auth_user_id,label,platform) values (' +
                          ','.join(sql_string(value) for value in values) + ') on conflict (id) do nothing;')
    statements.append('commit;')
    query('\n'.join(statements))
    contexts = {}
    for name in manifest['devices']:
        config = private_read(PRIVATE / (name + '.json'))
        context = rpc(config, 'ppomi_context', {})
        if context['device']['id'] != config['deviceId'] or context['workspace']['id'] != workspace:
            raise SafeError('Provisioned device context mismatch')
        contexts[name] = context['device']
    print(json.dumps({'projectRef': project, 'workspaceId': workspace, 'devices': contexts,
                      'privateConfigDirectory': str(PRIVATE)}, ensure_ascii=False, indent=2))


def configure_android(device, serial):
    if device == 'emulator' and not re.fullmatch(r'emulator-[0-9]+', serial):
        raise SafeError('Emulator credentials require an emulator serial')
    if device == 'fold' and (serial.startswith('emulator-') or not re.fullmatch(r'[A-Za-z0-9_-]+', serial)):
        raise SafeError('Physical device credentials require an explicit physical serial')
    config = private_read(PRIVATE / (device + '.json'))
    adb = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))) / 'platform-tools/adb'
    result = subprocess.run([str(adb), '-s', serial, 'shell', 'am', 'start', '-W',
        '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-f', '0x14000000', '-n',
        'com.ppomi.androidbridge/.DebugProvisioningActivity', '--es', 'ssot_config',
        shlex.quote(json.dumps(config, separators=(',', ':')))], capture_output=True, text=True, timeout=35)
    if result.returncode or 'Error:' in result.stdout or 'Error:' in result.stderr:
        raise SafeError('Android debug configuration import could not be started')
    print(json.dumps({'device': device, 'serial': serial, 'importStarted': True,
                      'verification': 'Check the app shared-server cache/UI for connected state'}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    setup = commands.add_parser('bootstrap')
    setup.add_argument('--project-ref', required=True)
    call = commands.add_parser('rpc')
    call.add_argument('--device', choices=['mac', 'emulator', 'fold'], required=True)
    call.add_argument('--function', required=True)
    call.add_argument('--params-file', type=Path)
    android = commands.add_parser('configure-android')
    android.add_argument('--device', choices=['emulator', 'fold'], required=True)
    android.add_argument('--serial', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'bootstrap':
            bootstrap(args.project_ref)
        elif args.command == 'configure-android':
            configure_android(args.device, args.serial)
        else:
            params = json.loads(args.params_file.read_text()) if args.params_file else {}
            print(json.dumps(rpc(private_read(PRIVATE / (args.device + '.json')), args.function, params),
                             ensure_ascii=False, indent=2))
    except SafeError as error:
        raise SystemExit(str(error)) from None
    except (KeyError, ValueError, OSError):
        raise SystemExit('Shared server setup failed; check private configuration and CLI state') from None


if __name__ == '__main__':
    main()
