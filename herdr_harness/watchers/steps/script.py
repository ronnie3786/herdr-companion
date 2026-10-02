"""Script execution with isolated control settings and bounded result payloads."""
from __future__ import annotations

import os
import pwd
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from ...child_environment import agent_environment
from ..errors import WatchersError
from ..store import private_dir, private_write

OUTPUT_LIMIT = 2 * 1024 * 1024


class RunStopped(Exception):
    pass


def environment(environ, *, watcher_id, run_id, step_id, input_path, output_path, state_dir):
    value = {k: v for k, v in agent_environment(environ, integration=False).items() if not k.startswith('HERDR_')}
    account = pwd.getpwuid(os.getuid())
    value.setdefault('HOME', account.pw_dir)
    value.setdefault('USER', account.pw_name)
    value.setdefault('LOGNAME', value['USER'])
    value.setdefault('SHELL', '/bin/sh')
    value.setdefault('TMPDIR', '/tmp')
    value.setdefault('LANG', 'en_US.UTF-8')
    value['PATH'] = environ.get('HERDR_WATCHERS_PATH') or f"{Path(sys.executable).parent}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    value.update(HERDR_WATCHER_ID=watcher_id, HERDR_WATCHER_RUN_ID=run_id, HERDR_WATCHER_STEP_ID=step_id,
                 HERDR_WATCHER_INPUT=str(input_path), HERDR_WATCHER_OUTPUT=str(output_path), HERDR_WATCHER_STATE_DIR=str(state_dir))
    return value


def kill_group(pid, sig=signal.SIGKILL):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def execute(step, *, run_dir, watcher_id, run_id, input_path, state_dir, environ, stopped, on_process=None, execution_lock=None):
    run_dir = Path(run_dir)
    step_dir = private_dir(run_dir / 'steps' / step['id'])
    stdout_path, stderr_path = step_dir / 'stdout.log', step_dir / 'stderr.log'
    output_path, result_path = step_dir / 'output', step_dir / 'result'
    env = environment(environ, watcher_id=watcher_id, run_id=run_id, step_id=step['id'],
                      input_path=input_path, output_path=output_path, state_dir=state_dir)
    interpreter = shutil.which(step.get('interpreter', '/bin/bash'), path=env['PATH'])
    if not interpreter:
        raise WatchersError('interpreter_missing', f"Interpreter unavailable: {step.get('interpreter')}")
    script = run_dir / 'scripts' / step['file']
    cwd = Path(step.get('cwd') or run_dir).expanduser()
    started = time.monotonic()
    timed_out, was_stopped = False, False
    private_write(stdout_path, '')
    private_write(stderr_path, '')
    with stdout_path.open('wb') as stdout, stderr_path.open('wb') as stderr:
        process = subprocess.Popen([interpreter, str(script)], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True,
                                   pass_fds=(execution_lock,) if execution_lock is not None else ())
        if on_process:
            on_process(process.pid)
        try:
            while process.poll() is None:
                if stopped():
                    was_stopped = True
                    kill_group(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        kill_group(process.pid)
                    break
                if time.monotonic() - started >= step.get('timeout_seconds', 3600):
                    timed_out = True
                    kill_group(process.pid)
                    break
                time.sleep(0.1)
            process.wait()
        except BaseException:
            kill_group(process.pid)
            process.wait()
            raise
        finally:
            # Background descendants belong to this step too. Their inherited
            # execution lock must not outlive a successfully completed step.
            if not timed_out:
                try:
                    kill_group(process.pid)
                except PermissionError:
                    # On Darwin a group containing only reaped/zombie children
                    # can return EPERM after its leader has already exited. The
                    # live-process timeout/stop signals above remain strict.
                    pass
            if on_process:
                on_process(None)
    selected = output_path if output_path.is_file() else stdout_path
    with selected.open('rb') as handle:
        content = handle.read(OUTPUT_LIMIT + 1)
    truncated = len(content) > OUTPUT_LIMIT
    fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(content[:OUTPUT_LIMIT])
    status = 'timed_out' if timed_out else ('stopped' if was_stopped else ('ok' if process.returncode in (0, 75) else 'failed'))
    return {'status': status, 'exit_code': process.returncode, 'signal': -process.returncode if process.returncode < 0 else None,
            'stdout_path': str(stdout_path), 'stderr_path': str(stderr_path), 'output_ref': str(result_path),
            'stdout_bytes': stdout_path.stat().st_size, 'stderr_bytes': stderr_path.stat().st_size,
            'output_truncated': truncated, 'duration_seconds': time.monotonic() - started}
