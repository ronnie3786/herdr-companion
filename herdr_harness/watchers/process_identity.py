"""Check OS process birth identity before signaling persisted worker PIDs.

PIDs alone are reusable after a companion restart. Darwin exposes microsecond
birth time through libproc; Linux exposes boot ID plus start ticks in procfs.
Unreadable or unsupported identity fails closed. Identity verification reduces
PID reuse risk, but group signaling remains a check followed by a syscall.
"""
from __future__ import annotations

import ctypes
from functools import lru_cache
import os
from pathlib import Path
import sys


class _BsdInfo(ctypes.Structure):
    # sys/proc_info.h: struct proc_bsdinfo, PROC_PIDTBSDINFO (3).
    _fields_ = [
        (name, ctypes.c_uint32) for name in (
            'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
            'rgid', 'svuid', 'svgid', 'reserved',
        )
    ] + [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tty', 'tpgid')
    ] + [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


@lru_cache(maxsize=1)
def _libproc():
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _darwin_identity(pid):
    info = _BsdInfo()
    size = _libproc().proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info) or info.pid != pid or not info.start_sec or not info.pgid:
        return None
    return {'pid': pid, 'started': f'darwin:{info.start_sec}:{info.start_usec}', 'pgid': info.pgid, 'uid': info.uid}


def _linux_stat(pid):
    # The parenthesized command name may itself contain spaces and parentheses.
    text = Path(f'/proc/{pid}/stat').read_text()
    if int(text.split(' ', 1)[0]) != pid:
        return None
    fields = text.rsplit(')', 1)[1].split()
    return int(fields[19]), int(fields[2])  # Original fields 22 (starttime), 5 (pgrp).


def _linux_identity(pid):
    first = _linux_stat(pid)
    if first is None:
        return None
    status = Path(f'/proc/{pid}/status').read_text()
    uid_line = next((line.split() for line in status.splitlines() if line.startswith('Uid:')), None)
    if uid_line is None:
        return None
    uid = int(uid_line[2])  # Effective UID, like Darwin pbi_uid.
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    second = _linux_stat(pid)
    if first != second or not boot or first[0] < 0 or first[1] <= 0 or uid < 0:
        return None
    return {'pid': pid, 'started': f'linux:{boot}:{first[0]}', 'pgid': first[1], 'uid': uid}


def process_identity(pid: int) -> dict | None:
    if type(pid) is not int or pid <= 1:
        return None
    try:
        if sys.platform == 'darwin':
            return _darwin_identity(pid)
        if sys.platform.startswith('linux'):
            return _linux_identity(pid)
    except (OSError, ValueError, IndexError, AttributeError):
        return None
    return None


def same_process(pid: int, expected: dict | None) -> bool:
    if not isinstance(expected, dict) or expected.get('pid') != pid:
        return False
    actual = process_identity(pid)
    return actual is not None and all(actual.get(key) == expected.get(key) for key in ('pid', 'started', 'pgid', 'uid'))


def signal_process(pid: int, expected: dict | None, sig: int, *, group: bool = False) -> bool:
    """Signal only the recorded process owned by this user, or its own group."""
    if not isinstance(expected, dict) or expected.get('uid') != os.geteuid():
        return False
    if group and expected.get('pgid') != pid:
        return False
    if not same_process(pid, expected):
        return False
    try:
        (os.killpg if group else os.kill)(pid, sig)
    except (OSError, ValueError):
        return False
    return True
