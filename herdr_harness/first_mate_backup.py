"""Bounded private recovery archives. Never stash, reset, commit, or auto-restore."""
from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import selectors
import shutil
import stat
import subprocess
import time
import uuid
import zipfile


class BackupUnavailable(RuntimeError):
    pass


def git_bytes(cwd: str, *args: str, limit: int = 64 * 1024 * 1024) -> bytes:
    """Bound both output and time, including misconfigured Git helpers."""
    process = subprocess.Popen(['git', '--no-optional-locks', '-C', cwd, *args],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output = bytearray()
    deadline = time.monotonic() + 30
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, True)
            selector.register(process.stderr, selectors.EVENT_READ, False)
            while selector.get_map():
                if time.monotonic() > deadline:
                    raise BackupUnavailable('Git inspection exceeded its deadline')
                for key, _ in selector.select(.1):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                    elif key.data:
                        output.extend(data)
                        if len(output) > limit:
                            raise BackupUnavailable('Git evidence exceeds the recovery archive limit')
            if process.wait(timeout=max(.1, deadline - time.monotonic())):
                raise BackupUnavailable('Git evidence could not be inspected')
        return bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        process.stdout.close()
        process.stderr.close()


def capture_backup(runtime, job: dict) -> dict:
    """One immutable archive per stopped execution; receipt recreation is safe."""
    if job.get('workspace_mode') == 'read_only':
        return {'status': 'not_needed', 'reason': 'Read-only assignment'}
    cwd = Path(job['cwd']).resolve()
    if not cwd.is_relative_to((runtime.root / 'worktrees').resolve()):
        raise BackupUnavailable('Automatic continuation requires a managed isolated worktree')
    root = runtime.root / 'recovery-backups'
    root.mkdir(mode=0o700, exist_ok=True)
    archive = root / (job['id'] + '.zip')
    limit = 64 * 1024 * 1024
    archive_limit = 72 * 1024 * 1024  # Payload plus bounded ZIP/manifest overhead.
    if archive.exists():
        if archive.stat().st_size > archive_limit:
            raise BackupUnavailable('Existing recovery archive exceeds its bounded size')
        try:
            with zipfile.ZipFile(archive) as saved:
                entries = saved.infolist()
                if len(entries) > 10003 or sum(entry.file_size for entry in entries) > archive_limit:
                    raise BackupUnavailable('Existing recovery archive exceeds its bounded contents')
                manifest = json.loads(saved.read('manifest.json'))
                if not isinstance(manifest, dict) or manifest.get('job_id') != job['id'] or manifest.get('workspace_path') != str(cwd) or saved.testzip() is not None:
                    raise BackupUnavailable('Existing recovery archive failed verification')
        except (zipfile.BadZipFile, ValueError, KeyError, RuntimeError, NotImplementedError) as error:
            raise BackupUnavailable('Existing recovery archive failed verification') from error
        return {'status': 'saved', 'path': str(archive), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
    if sum(path.stat().st_size for path in root.glob('*.zip')) + archive_limit > 1024 * 1024 * 1024:
        raise BackupUnavailable('Recovery archives reached their 1 GiB quota; retained archives were not deleted')
    if shutil.disk_usage(root).free < runtime.minimum_free_bytes + archive_limit:
        error = OSError(errno.ENOSPC, 'Waiting for free-space reserve before preserving a recovery archive')
        error.storage_low = True
        raise error
    head = git_bytes(str(cwd), 'rev-parse', 'HEAD', limit=1024).decode().strip()
    patch = git_bytes(str(cwd), 'diff', '--no-ext-diff', '--no-textconv', '--binary', 'HEAD', '--', limit=limit)
    staged = git_bytes(str(cwd), 'diff', '--no-ext-diff', '--no-textconv', '--binary', '--cached', '--', limit=limit)
    names = git_bytes(str(cwd), 'ls-files', '--others', '--exclude-standard', '-z', limit=1024 * 1024).split(b'\0')
    total = len(patch) + len(staged)
    if total > limit or len(names) > 10000:
        raise BackupUnavailable('Workspace evidence exceeds the bounded recovery archive')
    manifest = {'job_id': job['id'], 'workspace_path': str(cwd), 'head': head,
                'generation': job['claim']['generation'], 'native_session_id': job.get('native_session_id'),
                'untracked_symlinks': {}, 'limits': 'Tracked diff and non-ignored untracked files only; no automatic restore'}
    temporary = root / ('.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('xb') as handle:
            os.chmod(temporary, 0o600)
            with zipfile.ZipFile(handle, 'w', compression=zipfile.ZIP_DEFLATED) as saved:
                saved.writestr('tracked.patch', patch)
                saved.writestr('staged.patch', staged)
                for name in filter(None, names):
                    relative = PurePosixPath(os.fsdecode(name))
                    if relative.is_absolute() or '..' in relative.parts:
                        raise BackupUnavailable('Untracked path escaped the worktree')
                    path = cwd / relative
                    if not path.parent.resolve().is_relative_to(cwd):
                        raise BackupUnavailable('Untracked parent escaped the worktree')
                    info = path.lstat()
                    if stat.S_ISLNK(info.st_mode):
                        manifest['untracked_symlinks'][str(relative)] = os.readlink(path)
                        continue
                    if not stat.S_ISREG(info.st_mode) or info.st_size + total > limit:
                        raise BackupUnavailable('Untracked source cannot fit safely in a recovery archive')
                    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(descriptor, 'rb') as source:
                        actual = os.fstat(source.fileno())
                        if not stat.S_ISREG(actual.st_mode) or (actual.st_ino, actual.st_mtime_ns, actual.st_size) != (info.st_ino, info.st_mtime_ns, info.st_size):
                            raise BackupUnavailable('Untracked source changed during archive capture')
                        data = source.read(limit - total + 1)
                        after = os.fstat(source.fileno())
                        if (after.st_mtime_ns, after.st_size) != (actual.st_mtime_ns, actual.st_size):
                            raise BackupUnavailable('Untracked source changed during archive capture')
                    total += len(data)
                    if total > limit:
                        raise BackupUnavailable('Workspace changed beyond the recovery archive limit')
                    entry = zipfile.ZipInfo('untracked/' + str(relative))
                    entry.external_attr = info.st_mode << 16
                    saved.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED)
                saved.writestr('manifest.json', json.dumps(manifest, ensure_ascii=False))
            if handle.tell() > archive_limit:
                raise BackupUnavailable('Serialized recovery archive exceeds its bounded size')
            handle.flush()
            os.fsync(handle.fileno())
        if (git_bytes(str(cwd), 'rev-parse', 'HEAD', limit=1024).decode().strip() != head
                or git_bytes(str(cwd), 'diff', '--no-ext-diff', '--no-textconv', '--binary', 'HEAD', '--', limit=limit) != patch
                or git_bytes(str(cwd), 'diff', '--no-ext-diff', '--no-textconv', '--binary', '--cached', '--', limit=limit) != staged):
            raise BackupUnavailable('Tracked source changed during archive capture')
        os.replace(temporary, archive)
        descriptor = os.open(root, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)
    return {'status': 'saved', 'path': str(archive), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
