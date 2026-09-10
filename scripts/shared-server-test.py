#!/usr/bin/env python3
"""Exercise the real Mac MCP -> Supabase boundary with synthetic records only.

seed creates a fixed-ID fixture run for explicitly starting on Android.
verify reads its completed state back through Mac MCP; it never executes a UI action.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared_server', ROOT / 'scripts/shared-server.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def mcp(binary, name, arguments, expect_error=False):
    request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
               'params': {'name': name, 'arguments': arguments}}
    process = subprocess.run([str(binary), '--mcp'], input=json.dumps(request) + '\n',
                             capture_output=True, text=True, timeout=75)
    if process.returncode:
        raise shared.SafeError('Mac MCP process failed')
    responses = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
    response = next(item['result'] for item in responses if item.get('id') == 1)
    if bool(response.get('isError')) != expect_error:
        raise shared.SafeError('Unexpected MCP result for ' + name)
    if expect_error:
        return response
    return json.loads(response['content'][0]['text'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['seed', 'verify'])
    parser.add_argument('--executor', choices=['emulator', 'fold'], default='emulator')
    parser.add_argument('--binary', type=Path, default=ROOT / 'dist/Ppomi.app/Contents/MacOS/Ppomi')
    args = parser.parse_args()
    proof_path = shared.PRIVATE / ('proof-' + args.executor + '.json')
    try:
        if args.command == 'seed':
            if proof_path.exists():
                raise shared.SafeError('Proof already exists; inspect it instead of creating a duplicate run')
            devices = shared.private_read(shared.PRIVATE / 'devices.json')
            run_id = str(uuid.uuid4())
            document_id = 'test:ssot-' + uuid.uuid4().hex
            proof = {'runId': run_id, 'documentId': document_id, 'executor': args.executor,
                     'checks': [], 'phase': 'preparing'}
            shared.private_write(proof_path, proof)
            context = mcp(args.binary, 'shared_status', {})
            assert context['connected'] is True
            proof['checks'].append('mac_keychain_authenticated_device_context')
            executor_id = devices['devices'][args.executor]['id']
            create = {'runId': run_id, 'executorDeviceId': executor_id,
                      'request': 'Supabase SSOT 연결 테스트'}
            original = mcp(args.binary, 'shared_task_create', create)
            repeated = mcp(args.binary, 'shared_task_create', create)
            assert original == repeated and original['state'] == 'queued'
            proof['checks'].append('mac_mcp_run_create_exact_retry_is_idempotent')
            mcp(args.binary, 'shared_task_create', {**create, 'request': 'Changed input must fail'}, True)
            proof['checks'].append('run_id_reuse_with_different_input_rejected')
            doc = {'id': document_id, 'kind': 'rule', 'title': '공유 서버 테스트 규칙',
                   'body': {'synthetic': True, 'execution': 'device_local', 'revision': 1},
                   'expectedVersion': 0, 'operationId': str(uuid.uuid4())}
            first = mcp(args.binary, 'shared_document_put', doc)
            updated = mcp(args.binary, 'shared_document_put', {**doc, 'body': {**doc['body'], 'revision': 2},
                'expectedVersion': 1, 'operationId': str(uuid.uuid4())})
            assert first['version'] == 1 and updated['version'] == 2
            assert mcp(args.binary, 'shared_document_put', doc) == first
            mcp(args.binary, 'shared_document_put', {**doc, 'expectedVersion': 1, 'operationId': str(uuid.uuid4())}, True)
            assert mcp(args.binary, 'shared_documents', {'id': document_id})['version'] == 2
            proof['checks'] += ['shared_document_cas_1_to_2', 'document_retry_returns_original',
                                'stale_document_write_rejected_without_overwrite']
            try:
                shared.rpc(shared.private_read(shared.PRIVATE / 'mac.json'), 'ppomi_claim_run',
                           {'p_run_id': run_id, 'p_expected_version': 1})
                raise AssertionError('Mac must not claim Android work')
            except shared.SafeError as error:
                assert str(error).endswith('HTTP 403')
            proof['checks'].append('real_mac_auth_cannot_claim_android_execution')
            proof.update(phase='queued_for_explicit_android_start', serverState='queued', documentVersion=2)
            shared.private_write(proof_path, proof)
        else:
            proof = shared.private_read(proof_path)
            result = mcp(args.binary, 'shared_tasks', {'runId': proof['runId']})
            assert result['run']['state'] == 'completed', 'Android has not completed the fixture yet'
            assert len({event['event_id'] for event in result['events']}) == len(result['events'])
            assert result['run']['version'] == len(result['events'])
            proof.update(phase='verified', serverState='completed', serverVersion=result['run']['version'],
                         eventCount=len(result['events']))
            proof['checks'] += ['mac_mcp_reads_android_server_completion', 'one_server_event_per_version']
            shared.private_write(proof_path, proof)
        print(json.dumps(proof, ensure_ascii=False, indent=2))
    except (shared.SafeError, AssertionError) as error:
        raise SystemExit(str(error)) from None
    except (KeyError, ValueError, StopIteration, subprocess.TimeoutExpired):
        raise SystemExit('Shared server test failed; inspect local private proof and server state') from None


if __name__ == '__main__':
    main()
