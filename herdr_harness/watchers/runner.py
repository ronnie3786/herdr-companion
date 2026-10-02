"""Detached execution of a frozen Watcher revision, independent of clients."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import threading
from pathlib import Path

from ..code_factory.prompts import _GITHUB_TOKEN_RE, _PRIVATE_KEY_RE
from .process_identity import process_identity
from .steps import gate, script
from .store import RUNNING, WatchersStore, iso, private_dir, private_write

HEARTBEAT_SECONDS = 5


def scrub(text, environ):
    # Outbound prose must not repeat control or provider credentials printed by a tool.
    for name, value in environ.items():
        if len(value) >= 8 and any(word in name.upper() for word in ('TOKEN', 'SECRET', 'PASSWORD', 'API_KEY', 'PRIVATE_KEY')):
            text = text.replace(value, '[redacted]')
    text = _GITHUB_TOKEN_RE.sub('[redacted credential]', text)
    text = _PRIVATE_KEY_RE.sub('[redacted private key]', text)
    return re.sub(r'(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer [redacted]', text)


def run(run_dir, *, environ=None):
    run_dir = Path(run_dir).resolve()
    manifest = json.loads((run_dir / 'run.json').read_text(encoding='utf-8'))
    definition, run_id = manifest['definition'], manifest['run_id']
    environ = dict(os.environ if environ is None else environ)
    lock_fd = os.open(run_dir / 'runner.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        store = WatchersStore(manifest['store_path'], manifest['root'], manifest['machine'])
        if store.get_run(run_id)['status'] not in RUNNING:
            return 0
        stop, done = threading.Event(), threading.Event()
        old_handlers = {}
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, signal.SIGINT):
                old_handlers[sig] = signal.signal(sig, lambda *_: stop.set())

        def stopped():
            return stop.is_set() or bool(store.get_run(run_id)['stop_requested'])

        def heartbeat():
            while not done.wait(HEARTBEAT_SECONDS):
                try:
                    store.update_run(run_id, heartbeat_at=iso())
                    if store.get_run(run_id)['stop_requested']:
                        stop.set()
                except Exception:
                    # A transient database lock does not terminate a script.
                    continue

        store.update_run(run_id, status='running', pid=os.getpid(), pid_identity=process_identity(os.getpid()), heartbeat_at=iso())
        thread = threading.Thread(target=heartbeat, name='watcher-heartbeat', daemon=True)
        thread.start()
        outputs, cursors = {}, {}
        previous = run_dir / 'input'
        private_write(previous, '')
        state_dir = private_dir(Path(manifest['root']) / manifest['watcher_id'] / 'state')
        status, summary = 'finished', 'Finished. All steps completed.'
        try:
            for index, step in enumerate(definition['steps']):
                if stopped():
                    raise script.RunStopped()
                store.update_run(run_id, step_index=index, step_id=step['id'], step_title=step.get('title', step['kind']), heartbeat_at=iso())
                if step['kind'] == 'script':
                    result = script.execute(step, run_dir=run_dir, watcher_id=manifest['watcher_id'], run_id=run_id,
                                            input_path=previous, state_dir=state_dir, environ=environ, stopped=stopped,
                                            on_process=lambda pid: store.update_run(run_id, process_pid=pid, process_identity=process_identity(pid) if pid else None),
                                            execution_lock=lock_fd)
                    store.record_step(run_id, step['id'], result)
                    if result['status'] == 'stopped':
                        raise script.RunStopped()
                    if result['status'] in ('failed', 'timed_out'):
                        status = 'failed'
                        summary = f"Needs you. {step['title']} " + ('timed out.' if result['status'] == 'timed_out' else f"exited with code {result['exit_code']}.")
                        break
                    if result['exit_code'] == 75:
                        status, summary = 'nothing_new', 'Nothing new. The script had nothing to do.'
                        break
                    previous = Path(result['output_ref'])
                elif step['kind'] == 'gate':
                    rule = step['rule']
                    source = outputs[rule['from']] if rule.get('from') else previous
                    passed, output, cursor = gate.evaluate(rule, source.read_bytes(), store.gate_cursor(manifest['watcher_id'], step['id']))
                    previous = run_dir / f"gate-{step['id']}.json"
                    private_write(previous, output.decode('utf-8', errors='replace'))
                    store.record_step(run_id, step['id'], {'status': 'ok' if passed else 'skipped', 'output_ref': str(previous)})
                    if not passed:
                        status, summary = 'nothing_new', 'Nothing new. Stopped at the check.'
                        break
                    cursors[step['id']] = cursor
                elif step['kind'] == 'deliver':
                    body = scrub(previous.read_text(encoding='utf-8', errors='replace'), environ)
                    for destination in step['to']:
                        if destination['kind'] != 'inbox':
                            raise ValueError('Unsupported delivery in frozen revision')
                        if stopped():
                            raise script.RunStopped()
                        store.deliver_inbox(run_id, step['id'], destination, definition['name'], body,
                                            dry_run=manifest['trigger'] == 'dry_run')
                    store.record_step(run_id, step['id'], {'status': 'ok', 'would_post': manifest['trigger'] == 'dry_run'})
                else:
                    raise ValueError('Unsupported step in frozen revision')
                outputs[step['id']] = previous
                store.update_run(run_id, step_index=index + 1)
            if stopped():
                raise script.RunStopped()
            if manifest['trigger'] == 'dry_run' and status == 'finished':
                summary = 'Finished the dry run. Deliveries show what would post; check cursors were unchanged.'
        except script.RunStopped:
            status, summary = 'stopped', 'Stopped. Remaining steps were not run.'
        except BaseException as exc:
            status, summary = 'failed', scrub(f'Needs you. {type(exc).__name__}: {exc}', environ)[:1200]
        finally:
            done.set()
            thread.join(timeout=HEARTBEAT_SECONDS + 1)
            # finished_at is committed before the lock is released, including errors.
            store.complete_run(run_id, status, summary, cursors=cursors)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
        return 0 if status in ('finished', 'nothing_new', 'stopped') else 1
    finally:
        os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=Path)
    return run(parser.parse_args(argv).run)


if __name__ == '__main__':
    raise SystemExit(main())
