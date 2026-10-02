#!/usr/bin/env python3
"""Reproducible synthetic First Mate read/refresh benchmark, no provider calls.

Run with Python 3.11+ from the repository root. Default: 1 GiB retained history,
1,200 jobs, eight features, and a 40 MiB saved session. All state is temporary.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from herdr_harness.first_mate_runtime import FirstMateRuntime
from herdr_harness.first_mate_store import FirstMateStore


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history-mib', type=int, default=1024)
    parser.add_argument('--jobs', type=int, default=1200)
    parser.add_argument('--sessions', type=int, default=832)
    parser.add_argument('--features', type=int, default=8)
    parser.add_argument('--read-budget', type=float, default=5.0)
    args = parser.parse_args()
    assert 1 <= args.features <= args.sessions <= args.jobs and args.sessions >= 2
    assert args.history_mib >= 40
    evidence = {'history_mib_target': args.history_mib, 'jobs': args.jobs,
                'sessions': args.sessions, 'features': args.features, 'reads': []}
    with tempfile.TemporaryDirectory(prefix='herdr-synthetic-reads-') as temporary:
        root = Path(temporary)
        store = FirstMateStore(root / 'store.sqlite3')
        runtime = FirstMateRuntime(store, environ={'PATH': ''}, runtime_root=root / 'runtime')
        release = threading.Event()
        try:
            features = [store.create_feature({'title': f'Synthetic {i}', 'goal': 'Synthetic scale benchmark',
                'cwd': str(root), 'request_id': f'feature-{i}'}) for i in range(args.features)]
            sessions_root = runtime.root / 'sessions'
            sessions_root.mkdir()
            usage = {'input': 10, 'output': 2, 'cacheRead': 3, 'cacheWrite': 1, 'totalTokens': 16,
                     'cost': {'total': 1.0}}
            padding = json.dumps({'type': 'message', 'id': 'payload', 'message': {
                'role': 'toolResult', 'content': 'x' * (1024 * 1024 - 128)}}).encode() + b'\n'
            history_bytes = 0
            targets = [40 * 1024 * 1024] + [
                (args.history_mib - 40) * 1024 * 1024 // (args.sessions - 1)] * (args.sessions - 1)
            for index, target in enumerate(targets):
                path = sessions_root / f'session-{index}.jsonl'
                header = json.dumps({'type': 'session', 'id': f'native-{index}'}).encode() + b'\n'
                paid = json.dumps({'type': 'message', 'id': 'paid', 'message': {
                    'role': 'assistant', 'content': 'Synthetic response', 'provider': 'synthetic',
                    'model': 'synthetic', 'usage': usage}}).encode() + b'\n'
                with path.open('wb') as handle:
                    handle.write(header + paid)
                    remaining = target - len(header) - len(paid)
                    while remaining > 0:
                        handle.write(padding)
                        remaining -= len(padding)
                history_bytes += path.stat().st_size
            for index in range(args.jobs):
                session = index % args.sessions
                job_dir = runtime.jobs_root / f'job-{index:05}'
                job_dir.mkdir()
                # Large unrelated role metadata recreates job-inventory pressure.
                job = {'id': job_dir.name, 'feature_id': features[session % args.features]['id'],
                       'kind': 'coordinator', 'claim': {}, 'native_session_id': f'native-{session}',
                       'session_file': str(sessions_root / f'session-{session}.jsonl'),
                       'created_at': features[session % args.features]['created_at'],
                       'agent_role_snapshot': {'prompt': 'synthetic' * 8192}}
                (job_dir / 'job.json').write_text(json.dumps(job))
            evidence['history_bytes'] = history_bytes
            def timed(label, action):
                start = time.monotonic()
                value = action()
                seconds = time.monotonic() - start
                evidence['reads'].append({'label': label, 'seconds': round(seconds, 4)})
                assert seconds < args.read_budget, f'{label} exceeded {args.read_budget}s: {seconds:.3f}s'
                return value
            entered = threading.Event()
            original = runtime.usage._engine.account
            def blocked(**kw):
                entered.set()
                assert release.wait(180)
                return original(**kw)
            with mock.patch.object(runtime.usage._engine, 'account', side_effect=blocked):
                cold = timed('cold list, blocked accounting', runtime.list_features)
                assert all(f['usage']['cost_usd'] is None for f in cold)
                assert entered.wait(2)
                timed('cold chat, blocked accounting', lambda: runtime.read_view(features[0]['id']))
                with ThreadPoolExecutor(max_workers=3) as pool:
                    values = list(pool.map(lambda index: timed(f'concurrent cold {index}',
                        runtime.list_features if index == 0 else lambda: runtime.read_view(features[index]['id'])), range(3)))
                page = timed('40 MiB saved session, blocked accounting',
                    lambda: runtime.session('native-0', limit=1))
                assert page['messages'] and page['next_before'] is not None
                release.set()
                with runtime.usage._lock:
                    thread = runtime.usage._thread
                start = time.monotonic()
                if thread:
                    thread.join(timeout=300)
                    assert not thread.is_alive(), 'Initial refresh exceeded 300 seconds'
                evidence['initial_refresh_seconds'] = round(time.monotonic() - start, 4)
            # A pass whose scan was very long can honestly be stale until one
            # cheap stat-validated pass confirms its cached source summaries.
            runtime.list_features()
            with runtime.usage._lock:
                thread = runtime.usage._thread
            if thread:
                thread.join(timeout=120)
                assert not thread.is_alive()
            warm = timed('warm list', runtime.list_features)
            assert all(f['usage']['status'] == 'complete' for f in warm)
            assert sum(f['usage']['cost_usd'] for f in warm) == args.sessions
            assert sum(f['usage']['session_count'] for f in warm) == args.sessions
            timed('warm chat', lambda: runtime.read_view(features[0]['id']))
            timed('warm 40 MiB saved session', lambda: runtime.session('native-0', limit=1))
            with ThreadPoolExecutor(max_workers=3) as pool:
                list(pool.map(lambda index: timed(f'concurrent warm {index}',
                    runtime.list_features if index == 0 else lambda: runtime.read_view(features[index]['id'])), range(3)))
            evidence['usage_refresh'] = runtime.usage.health()
            evidence['ok'] = True
            print(json.dumps(evidence, indent=2))
        finally:
            release.set()
            runtime.stop()
            store.close()


if __name__ == '__main__':
    main()
