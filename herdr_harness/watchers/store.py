"""Private, transactional Watcher definitions and execution ledger.

Each operation opens its own SQLite connection. Detached workers never inherit
server connections, and the only long-lived resources are files and run locks.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from .errors import WatchersError
from .schedule import next_fire, schedule_summary
from .validation import validate_definition, summary_tokens, summary_text

UTC = timezone.utc
RUNNING = ('queued', 'running')
TERMINAL = ('finished', 'nothing_new', 'failed', 'stopped', 'unknown')
SCRIPT_LIMIT = 256 * 1024


def instant(value=None):
    if value is None:
        return datetime.now(UTC)
    if isinstance(value, datetime):
        return value.astimezone(UTC)
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, UTC)
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(UTC)


def iso(value=None):
    return instant(value).isoformat().replace('+00:00', 'Z')


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def private_dir(path):
    path = Path(path)
    missing = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o700, exist_ok=True)
        directory.chmod(0o700)
    path.chmod(0o700)
    return path


def private_write(path, value):
    path = Path(path)
    private_dir(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        handle.write(value)
    path.chmod(0o600)


_SCHEMA = '''
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS definitions(
 id TEXT PRIMARY KEY,revision INTEGER NOT NULL,state TEXT NOT NULL,
 definition_json TEXT NOT NULL,next_fire_at TEXT,source_key TEXT UNIQUE,
 created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS revisions(
 watcher_id TEXT NOT NULL REFERENCES definitions(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL,definition_json TEXT NOT NULL,created_at TEXT NOT NULL,
 PRIMARY KEY(watcher_id,revision));
CREATE TABLE IF NOT EXISTS drafts(
 watcher_id TEXT PRIMARY KEY REFERENCES definitions(id) ON DELETE CASCADE,
 builder_session_id TEXT);
CREATE TABLE IF NOT EXISTS runs(
 id TEXT PRIMARY KEY,watcher_id TEXT NOT NULL REFERENCES definitions(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL,trigger TEXT NOT NULL,scheduled_for TEXT,
 started_at TEXT NOT NULL,finished_at TEXT,status TEXT NOT NULL,pid INTEGER,
 heartbeat_at TEXT,summary TEXT NOT NULL DEFAULT '',snapshot_json TEXT NOT NULL,
 step_index INTEGER NOT NULL DEFAULT 0,step_id TEXT,step_title TEXT,
 stop_requested INTEGER NOT NULL DEFAULT 0,process_pid INTEGER,pid_identity TEXT,process_identity TEXT);
CREATE INDEX IF NOT EXISTS runs_watcher ON runs(watcher_id,started_at DESC);
CREATE INDEX IF NOT EXISTS runs_status ON runs(status);
CREATE TABLE IF NOT EXISTS step_runs(
 run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,step_id TEXT NOT NULL,
 status TEXT NOT NULL,data_json TEXT NOT NULL,PRIMARY KEY(run_id,step_id));
CREATE TABLE IF NOT EXISTS gate_state(
 watcher_id TEXT NOT NULL REFERENCES definitions(id) ON DELETE CASCADE,
 step_id TEXT NOT NULL,cursor_json TEXT NOT NULL,updated_at TEXT NOT NULL,
 PRIMARY KEY(watcher_id,step_id));
CREATE TABLE IF NOT EXISTS inbox_items(
 id TEXT PRIMARY KEY,watcher_id TEXT NOT NULL REFERENCES definitions(id) ON DELETE CASCADE,
 run_id TEXT,title TEXT NOT NULL,body_md TEXT NOT NULL,created_at TEXT NOT NULL,read_at TEXT);
CREATE TABLE IF NOT EXISTS deliveries(
 id TEXT PRIMARY KEY,run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
 step_id TEXT NOT NULL,destination_json TEXT NOT NULL,status TEXT NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0,data_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS receipts(
 request_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,response_json TEXT NOT NULL,created_at TEXT NOT NULL);
'''


class WatchersStore:
    def __init__(self, path, root, machine, *, clock=None):
        self.path, self.root = Path(path).expanduser(), Path(root).expanduser()
        self.machine = dict(machine) if isinstance(machine, dict) else {'id': machine, 'name': machine}
        self.clock = clock or (lambda: datetime.now(UTC))
        self._mutex = threading.RLock()
        private_dir(self.path.parent)
        private_dir(self.root)
        with self.connection() as db:
            db.executescript(_SCHEMA)
            columns = {row['name'] for row in db.execute('PRAGMA table_info(runs)')}
            for column in ('pid_identity', 'process_identity'):
                if column not in columns:
                    db.execute('ALTER TABLE runs ADD COLUMN ' + column + ' TEXT')
            db.execute("INSERT OR REPLACE INTO metadata VALUES('schema_version','2')")
        self.path.chmod(0o600)

    def now(self):
        return instant(self.clock())

    @contextmanager
    def connection(self, *, write=False):
        with self._mutex:
            db = sqlite3.connect(self.path, timeout=10)
            db.row_factory = sqlite3.Row
            try:
                db.execute('PRAGMA busy_timeout=10000')
                db.execute('PRAGMA journal_mode=WAL')
                db.execute('PRAGMA foreign_keys=ON')
                db.execute('PRAGMA synchronous=FULL')
                if write:
                    db.execute('BEGIN IMMEDIATE')
                yield db
                db.commit()
            except BaseException:
                db.rollback()
                raise
            finally:
                db.close()
                for path in (self.path, Path(str(self.path) + '-wal'), Path(str(self.path) + '-shm')):
                    try:
                        path.chmod(0o600)
                    except FileNotFoundError:
                        # SQLite can remove WAL/SHM as another process closes its
                        # last connection between our close and this chmod.
                        pass

    def _mutate(self, operation, payload, request_id, action):
        if request_id is not None and (not isinstance(request_id, str) or not request_id or len(request_id) > 200):
            raise WatchersError('invalid_request', 'request_id must be a nonempty string of at most 200 characters')
        fingerprint = hashlib.sha256(encoded([operation, payload]).encode()).hexdigest()
        with self.connection(write=True) as db:
            if request_id:
                receipt = db.execute('SELECT * FROM receipts WHERE request_id=?', (request_id,)).fetchone()
                if receipt:
                    if receipt['fingerprint'] != fingerprint:
                        raise WatchersError('idempotency_conflict', 'request_id was already used for another request', status=409)
                    if receipt['response_json'] != 'null':
                        return json.loads(receipt['response_json'])
            result = action(db)
            if request_id:
                db.execute('INSERT OR REPLACE INTO receipts VALUES(?,?,?,?)', (request_id, fingerprint, encoded(result), iso(self.now())))
            return result

    def _row(self, db, watcher_id):
        row = db.execute('SELECT * FROM definitions WHERE id=?', (watcher_id,)).fetchone()
        if row is None:
            raise WatchersError('watcher_not_found', 'Watcher not found', status=404)
        return row

    def _project(self, db, row):
        result = json.loads(row['definition_json'])
        result['schedule']['summary'] = schedule_summary(result['schedule'], result['timezone'], now=self.now())
        result['summary_tokens'] = summary_tokens(result['summary'], result['steps'], result['schedule']['summary'])
        result['summary_text'] = summary_text(result['summary'], result['steps'], result['schedule']['summary'])
        result.update(id=row['id'], revision=row['revision'], state=row['state'],
                      machine=self.machine, next_fire_at=row['next_fire_at'],
                      created_at=row['created_at'], updated_at=row['updated_at'])
        result['runs_count'] = db.execute('SELECT count(*) FROM runs WHERE watcher_id=?', (row['id'],)).fetchone()[0]
        live = db.execute("SELECT * FROM runs WHERE watcher_id=? AND status IN ('queued','running') ORDER BY started_at DESC LIMIT 1", (row['id'],)).fetchone()
        result['live'] = None if live is None else {
            'run_id': live['id'], 'step_index': live['step_index'],
            'step_count': len(json.loads(live['snapshot_json'])['steps']),
            'step_id': live['step_id'], 'step_title': live['step_title'], 'started_at': live['started_at'],
        }
        last = db.execute('SELECT * FROM runs WHERE watcher_id=? ORDER BY started_at DESC,rowid DESC LIMIT 1', (row['id'],)).fetchone()
        result['attention'] = None
        if last and last['status'] in ('failed', 'unknown'):
            result['attention'] = {'reason': last['summary'] or 'My last run needs attention.'}
        if last and db.execute("SELECT 1 FROM deliveries WHERE run_id=? AND status IN ('failed','unknown') LIMIT 1", (last['id'],)).fetchone():
            result['attention'] = {'reason': 'My last delivery needs attention.'}
        return result

    def get(self, watcher_id):
        with self.connection() as db:
            return self._project(db, self._row(db, watcher_id))

    def list(self, *, state=None, source=None):
        with self.connection() as db:
            rows = db.execute('SELECT * FROM definitions ORDER BY created_at,id').fetchall()
            return [self._project(db, row) for row in rows
                    if (state is None or row['state'] == state) and
                    (source is None or json.loads(row['definition_json']).get('source', {}).get('kind') == source)]

    def _normalize(self, definition):
        value = dict(definition)
        for key in ('live', 'attention', 'runs_count', 'next_fire_at', 'warnings'):
            value.pop(key, None)
        return validate_definition(value, machine_id=self.machine['id'])

    def _scripts(self, definition, scripts, *, previous=None):
        scripts = scripts or {}
        if not isinstance(scripts, dict):
            raise WatchersError('invalid_request', 'scripts must map step ids or filenames to script content')
        allowed = {value for step in definition['steps'] if step['kind'] == 'script' for value in (step['id'], step['file'])}
        if set(scripts) - allowed:
            raise WatchersError('invalid_script', 'Script keys must identify a script step or its filename')
        result = {}
        for step in definition['steps']:
            if step['kind'] != 'script':
                continue
            body = scripts.get(step['id'], scripts.get(step['file']))
            if isinstance(body, dict):
                body = body.get('content')
            if body is None and previous is not None:
                old = previous / step['file']
                if old.is_file():
                    body = old.read_text(encoding='utf-8')
            if body is None:
                continue  # Drafts may be incomplete; launch validates every body.
            if not isinstance(body, str) or '\x00' in body or len(body.encode()) > SCRIPT_LIMIT:
                raise WatchersError('invalid_script', 'Script content must be text of at most 256 KiB without NUL bytes')
            result[step['file']] = body
        return result

    def _write_revision(self, definition, scripts):
        revision_dir = self.root / definition['id'] / f"rev-{definition['revision']}"
        private_dir(revision_dir)
        for filename, body in scripts.items():
            target = revision_dir / filename
            if target.parent != revision_dir or filename in ('.', '..', 'definition.json'):
                raise WatchersError('invalid_script', 'Script filenames must be simple filenames')
            private_write(target, body)
        private_write(revision_dir / 'definition.json', encoded(definition))

    def _save(self, db, definition, scripts, *, creating=False):
        now = iso(self.now())
        state = definition['state']
        fire = next_fire(definition['schedule'], definition['timezone'], self.now()) if state == 'active' else None
        definition['updated_at'] = now
        self._write_revision(definition, scripts)
        if creating:
            source = definition.get('source') or {}
            source_key = f"cronboard:{source['job_id']}" if source.get('kind') == 'cronboard' else None
            db.execute('INSERT INTO definitions VALUES(?,?,?,?,?,?,?,?)', (
                definition['id'], definition['revision'], state, encoded(definition),
                iso(fire) if fire else None, source_key, definition['created_at'], now))
        else:
            db.execute('UPDATE definitions SET revision=?,state=?,definition_json=?,next_fire_at=?,updated_at=? WHERE id=?', (
                definition['revision'], state, encoded(definition), iso(fire) if fire else None, now, definition['id']))
        db.execute('INSERT INTO revisions VALUES(?,?,?,?)', (definition['id'], definition['revision'], encoded(definition), now))
        if state == 'draft':
            db.execute('INSERT OR REPLACE INTO drafts VALUES(?,?)', (definition['id'], definition.get('builder_session_id')))
        else:
            db.execute('DELETE FROM drafts WHERE watcher_id=?', (definition['id'],))
        return self._project(db, self._row(db, definition['id']))

    def _create(self, db, definition, scripts, state):
        value = self._normalize(definition)
        if state not in ('draft', 'paused'):
            raise WatchersError('invalid_state', 'New watchers start as drafts or paused imports')
        source = value.get('source') or {}
        if source.get('kind') == 'cronboard':
            existing = db.execute('SELECT * FROM definitions WHERE source_key=?', (f"cronboard:{source['job_id']}",)).fetchone()
            if existing:
                return self._project(db, existing)
        value.update(id='wat_' + uuid.uuid4().hex, revision=1, state=state, created_at=iso(self.now()))
        if state == 'paused' and definition.get('activated_by') == 'user':
            value.update(activated_by='user', activated_via=definition.get('activated_via', 'import'))
        else:
            value.pop('activated_by', None)
            value.pop('activated_via', None)
        return self._save(db, value, self._scripts(value, scripts), creating=True)

    def create(self, definition, *, scripts=None, request_id=None, state='draft'):
        return self._mutate('create', [definition, scripts, state], request_id,
                            lambda db: self._create(db, definition, scripts, state))

    def batch_create(self, entries, *, request_id=None):
        if not isinstance(entries, list) or not entries or len(entries) > 500:
            raise WatchersError('invalid_request', 'Import needs 1 to 500 watchers')
        # Validate every entry before any filesystem writes.
        for entry in entries:
            value = self._normalize(entry['definition'])
            self._scripts(value, entry.get('scripts'))
            state = entry.get('state', 'draft')
            if state not in ('draft', 'paused'):
                raise WatchersError('invalid_state', 'Imports start as drafts or paused watchers')
        return self._mutate('batch_create', entries, request_id,
                            lambda db: [self._create(db, e['definition'], e.get('scripts'), e.get('state', 'draft')) for e in entries])

    def _edit(self, db, watcher_id, changes, expected_revision, scripts=None):
        row = self._row(db, watcher_id)
        if expected_revision != row['revision']:
            raise WatchersError('revision_conflict', 'Watcher changed. Fetch its latest revision before saving.', status=409)
        value = json.loads(row['definition_json'])
        forbidden = {'id', 'revision', 'state', 'created_at', 'updated_at', 'activated_by', 'activated_via', 'source', 'edit_target_id', 'edit_target_revision'}
        if forbidden.intersection(changes):
            raise WatchersError('invalid_request', 'This field is managed by the watcher lifecycle')
        value.update(changes)
        value = self._normalize(value)
        previous = self.root / watcher_id / f"rev-{row['revision']}"
        bodies = self._scripts(value, scripts, previous=previous)
        if value['state'] == 'active':
            from .runtime import validate_executable
            validate_executable(value)
            if any(step['kind'] == 'script' and step['file'] not in bodies for step in value['steps']):
                raise WatchersError('script_missing', 'Every active script step needs a body', status=409)
        value['revision'] = row['revision'] + 1
        return self._save(db, value, bodies)

    def patch(self, watcher_id, patch, expected_revision, *, request_id=None, scripts=None):
        return self._mutate('patch', [watcher_id, patch, expected_revision, scripts], request_id,
                            lambda db: self._edit(db, watcher_id, patch, expected_revision, scripts))

    def set_script(self, watcher_id, step_id, body, expected_revision, *, request_id=None):
        def action(db):
            row = self._row(db, watcher_id)
            value = json.loads(row['definition_json'])
            if not any(step['id'] == step_id and step['kind'] == 'script' for step in value['steps']):
                raise WatchersError('step_not_found', 'Script step not found', status=404)
            return self._edit(db, watcher_id, {}, expected_revision, {step_id: body})
        return self._mutate('set_script', [watcher_id, step_id, body, expected_revision], request_id, action)

    def get_script(self, watcher_id, step_id):
        definition = self.get(watcher_id)
        step = next((s for s in definition['steps'] if s['id'] == step_id and s['kind'] == 'script'), None)
        if step is None:
            raise WatchersError('step_not_found', 'Script step not found', status=404)
        path = self.root / watcher_id / f"rev-{definition['revision']}" / step['file']
        return {'step_id': step_id, 'file': step['file'], 'content': path.read_text(encoding='utf-8') if path.exists() else '',
                'exists': path.exists(), 'revision': definition['revision']}

    def _transition(self, db, watcher_id, state, confirmed_by, activated_via):
        row = self._row(db, watcher_id)
        value = json.loads(row['definition_json'])
        if state not in ('active', 'paused'):
            raise WatchersError('invalid_state', 'Use active or paused')
        if state == 'active':
            if value.get('edit_target_id'):
                raise WatchersError('staged_edit_requires_save', 'Save this edit into its original watcher', status=409)
            if value.get('activated_by') != 'user' and confirmed_by != 'user':
                raise WatchersError('confirmation_required', 'A person must confirm activation', status=409)
            from .runtime import validate_executable
            validate_executable(value)
            self._require_scripts(value)
            if confirmed_by == 'user':
                value.update(activated_by='user', activated_via=activated_via or 'api')
        if state == row['state']:
            return self._project(db, row)
        value.update(state=state, revision=row['revision'] + 1)
        previous = self.root / watcher_id / f"rev-{row['revision']}"
        return self._save(db, value, self._scripts(value, None, previous=previous))

    def transition(self, watcher_id, state, *, request_id=None, confirmed_by=None, activated_via=None):
        return self.transition_many([watcher_id], state, request_id=request_id,
                                    confirmed_by=confirmed_by, activated_via=activated_via)[0]

    def transition_many(self, watcher_ids, state, *, request_id=None, confirmed_by=None, activated_via=None):
        return self._mutate('transition', [watcher_ids, state, confirmed_by, activated_via], request_id,
                            lambda db: [self._transition(db, wid, state, confirmed_by, activated_via) for wid in watcher_ids])

    def delete(self, watcher_id, *, force=False, request_id=None):
        def action(db):
            row = self._row(db, watcher_id)
            live = db.execute("SELECT 1 FROM runs WHERE watcher_id=? AND status IN ('queued','running')", (watcher_id,)).fetchone()
            if live or (row['state'] == 'active' and not force):
                raise WatchersError('watcher_busy', 'Pause the watcher and stop its run before deleting', status=409)
            db.execute('DELETE FROM definitions WHERE id=?', (watcher_id,))
            return {'id': watcher_id, 'deleted': True}
        result = self._mutate('delete', [watcher_id, force], request_id, action)
        # Retained running workers can never reach this path.
        shutil.rmtree(self.root / watcher_id, ignore_errors=True)
        return result

    def export(self, watcher_id):
        value = self.get(watcher_id)
        return {'format': 'herdr-watchers-v1', 'definition': value,
                'scripts': {s['id']: self.get_script(watcher_id, s['id'])['content'] for s in value['steps'] if s['kind'] == 'script'}}

    def _require_scripts(self, definition):
        for step in definition['steps']:
            if step['kind'] == 'script' and not (self.root / definition['id'] / f"rev-{definition['revision']}" / step['file']).is_file():
                raise WatchersError('script_missing', f"Add the script for {step['title']} before running", status=409)

    def _create_run(self, db, watcher_id, trigger, scheduled_for, capacity):
        definition = json.loads(self._row(db, watcher_id)['definition_json'])
        from .runtime import validate_executable
        validate_executable(definition)
        self._require_scripts(definition)
        if db.execute("SELECT 1 FROM runs WHERE watcher_id=? AND status IN ('queued','running')", (watcher_id,)).fetchone():
            raise WatchersError('watcher_busy', 'Watcher is already working; this fire was skipped', status=409)
        if db.execute("SELECT count(*) FROM runs WHERE status IN ('queued','running')").fetchone()[0] >= capacity:
            raise WatchersError('watchers_capacity', 'Watcher capacity is full; this fire was skipped', status=409)
        run_id, now = 'wrun_' + uuid.uuid4().hex, iso(self.now())
        run_dir = private_dir(self.root / watcher_id / 'runs' / run_id)
        frozen = private_dir(run_dir / 'scripts')
        for step in definition['steps']:
            if step['kind'] == 'script':
                source = self.root / watcher_id / f"rev-{definition['revision']}" / step['file']
                private_write(frozen / step['file'], source.read_text(encoding='utf-8'))
        manifest = {'run_id': run_id, 'watcher_id': watcher_id, 'store_path': str(self.path.resolve()),
                    'root': str(self.root.resolve()), 'machine': self.machine, 'definition': definition,
                    'trigger': trigger, 'runtime_path': str(Path(__file__).resolve().parents[2])}
        private_write(run_dir / 'run.json', encoded(manifest))
        db.execute('''INSERT INTO runs(id,watcher_id,revision,trigger,scheduled_for,started_at,status,heartbeat_at,snapshot_json)
                      VALUES(?,?,?,?,?,?,?,?,?)''', (run_id, watcher_id, definition['revision'], trigger,
                      iso(scheduled_for) if scheduled_for else None, now, 'queued', now, encoded(definition)))
        return self._run(db, db.execute('SELECT * FROM runs WHERE id=?', (run_id,)).fetchone())

    def create_run(self, watcher_id, trigger, *, scheduled_for=None, request_id=None, capacity=4):
        if trigger not in ('manual', 'dry_run', 'scheduled', 'catch_up'):
            raise WatchersError('invalid_request', 'Unknown watcher run trigger')
        scheduled_for = iso(scheduled_for) if scheduled_for else None
        return self._mutate('create_run', [watcher_id, trigger, scheduled_for], request_id,
                            lambda db: self._create_run(db, watcher_id, trigger, scheduled_for, capacity))

    def claim_due(self, watcher_id, scheduled_for, trigger, next_fire_at, *, capacity=4):
        """Record the run and advance its schedule in one crash-safe transaction."""
        with self.connection(write=True) as db:
            row = self._row(db, watcher_id)
            if row['state'] != 'active' or row['next_fire_at'] != iso(scheduled_for):
                return None  # Another mutation already changed this schedule.
            run = None
            if trigger:
                try:
                    run = self._create_run(db, watcher_id, trigger, iso(scheduled_for), capacity)
                except WatchersError as exc:
                    if exc.code not in ('watcher_busy', 'watchers_capacity'):
                        raise
            db.execute('UPDATE definitions SET next_fire_at=? WHERE id=?',
                       (iso(next_fire_at) if next_fire_at else None, watcher_id))
            return run

    def _run(self, db, row):
        value = dict(row)
        snapshot = json.loads(value.pop('snapshot_json'))
        for field in ('pid_identity', 'process_identity'):
            value[field] = json.loads(value[field]) if value.get(field) else None
        value['step_count'] = len(snapshot['steps'])
        value['duration_seconds'] = max(0, (instant(value['finished_at']) - instant(value['started_at'])).total_seconds()) if value['finished_at'] else None
        value['step_runs'] = [json.loads(r['data_json']) for r in db.execute('SELECT * FROM step_runs WHERE run_id=? ORDER BY rowid', (row['id'],))]
        value['deliveries'] = [dict(r, destination=json.loads(r['destination_json']), data=json.loads(r['data_json'])) for r in db.execute('SELECT * FROM deliveries WHERE run_id=? ORDER BY rowid', (row['id'],))]
        for delivery in value['deliveries']:
            delivery.pop('destination_json')
            delivery.pop('data_json')
        return value

    def get_run(self, run_id):
        with self.connection() as db:
            row = db.execute('SELECT * FROM runs WHERE id=?', (run_id,)).fetchone()
            if row is None:
                raise WatchersError('run_not_found', 'Watcher run not found', status=404)
            return self._run(db, row)

    def runs(self, watcher_id=None, *, status=None, source=None, limit=100, before=None):
        statuses = status.split(',') if isinstance(status, str) else status
        clauses, parameters = [], []
        if before is not None:
            clauses.append('r.started_at<?')
            parameters.append(self._before(before))
        if watcher_id:
            clauses.append('r.watcher_id=?')
            parameters.append(watcher_id)
        if statuses:
            clauses.append('r.status IN (' + ','.join('?' for _ in statuses) + ')')
            parameters.extend(statuses)
        if source is not None:
            clauses.append("json_extract(d.definition_json,'$.source.kind')=?")
            parameters.append(source)
        where = ' WHERE ' + ' AND '.join(clauses) if clauses else ''
        parameters.append(max(1, min(int(limit), 1000)))
        with self.connection() as db:
            if watcher_id:
                self._row(db, watcher_id)
            rows = db.execute('SELECT r.* FROM runs r JOIN definitions d ON d.id=r.watcher_id' + where +
                              ' ORDER BY r.started_at DESC,r.rowid DESC LIMIT ?', parameters).fetchall()
            return [self._run(db, row) for row in rows]

    def update_run(self, run_id, **changes):
        allowed = {'status', 'pid', 'heartbeat_at', 'summary', 'step_index', 'step_id', 'step_title', 'finished_at', 'stop_requested', 'process_pid', 'pid_identity', 'process_identity'}
        if not changes or not set(changes) <= allowed:
            raise ValueError('Invalid run update')
        changes = {key: encoded(value) if key.endswith('_identity') and value is not None else value for key, value in changes.items()}
        with self.connection(write=True) as db:
            db.execute('UPDATE runs SET ' + ','.join(key + '=?' for key in changes) + ' WHERE id=?', (*changes.values(), run_id))

    def record_step(self, run_id, step_id, result):
        value = dict(result, step_id=step_id)
        with self.connection(write=True) as db:
            db.execute('INSERT OR REPLACE INTO step_runs VALUES(?,?,?,?)', (run_id, step_id, value['status'], encoded(value)))

    def gate_cursor(self, watcher_id, step_id):
        with self.connection() as db:
            row = db.execute('SELECT cursor_json FROM gate_state WHERE watcher_id=? AND step_id=?', (watcher_id, step_id)).fetchone()
            return json.loads(row[0]) if row else None

    def complete_run(self, run_id, status, summary, *, cursors=None):
        with self.connection(write=True) as db:
            row = db.execute('SELECT * FROM runs WHERE id=?', (run_id,)).fetchone()
            if row is None or row['status'] not in RUNNING:
                return
            now = iso(self.now())
            db.execute('UPDATE runs SET status=?,summary=?,finished_at=?,heartbeat_at=?,process_pid=NULL WHERE id=?', (status, summary, now, now, run_id))
            if status == 'finished' and row['trigger'] != 'dry_run':
                for step_id, cursor in (cursors or {}).items():
                    db.execute('INSERT OR REPLACE INTO gate_state VALUES(?,?,?,?)', (row['watcher_id'], step_id, encoded(cursor), now))
            definition_row = self._row(db, row['watcher_id'])
            definition = json.loads(definition_row['definition_json'])
            # Completion applies to the pinned one-time definition only, never a newly edited schedule.
            if row['trigger'] != 'dry_run' and definition['schedule']['kind'] == 'once' and definition_row['revision'] == row['revision']:
                definition.update(state='done', revision=definition['revision'] + 1)
                previous = self.root / row['watcher_id'] / f"rev-{row['revision']}"
                self._save(db, definition, self._scripts(definition, None, previous=previous))
            if status in ('failed', 'unknown') and row['trigger'] != 'dry_run':
                db.execute('INSERT INTO inbox_items VALUES(?,?,?,?,?,?,NULL)', ('win_' + uuid.uuid4().hex, row['watcher_id'], run_id,
                           f"{definition['name']} needs you", summary, now))

    def deliver_inbox(self, run_id, step_id, destination, title, body, *, dry_run=False):
        delivery_id = 'wdel_' + uuid.uuid4().hex
        with self.connection(write=True) as db:
            row = db.execute('SELECT * FROM runs WHERE id=?', (run_id,)).fetchone()
            if row['stop_requested'] or row['status'] not in RUNNING:
                raise WatchersError('run_stopped', 'The run was stopped', status=409)
            data = {'title': title, 'body_md': body, 'would_post': dry_run}
            db.execute('INSERT INTO deliveries VALUES(?,?,?,?,?,?,?)', (delivery_id, run_id, step_id, encoded(destination),
                        'would_post' if dry_run else 'sent', 0 if dry_run else 1, encoded(data)))
            if not dry_run:
                db.execute('INSERT INTO inbox_items VALUES(?,?,?,?,?,?,NULL)', ('win_' + uuid.uuid4().hex, row['watcher_id'], run_id,
                            title, body, iso(self.now())))
        return delivery_id

    def inbox(self, watcher_id=None, *, source=None, limit=200, before=None, unread=False):
        clauses, parameters = [], []
        if before is not None:
            clauses.append('i.created_at<?')
            parameters.append(self._before(before))
        if unread:
            clauses.append('i.read_at IS NULL')
        if watcher_id is not None:
            clauses.append('i.watcher_id=?')
            parameters.append(watcher_id)
        if source is not None:
            clauses.append("json_extract(d.definition_json,'$.source.kind')=?")
            parameters.append(source)
        where = ' WHERE ' + ' AND '.join(clauses) if clauses else ''
        parameters.append(max(1, min(int(limit), 1000)))
        with self.connection() as db:
            rows = db.execute('SELECT i.* FROM inbox_items i JOIN definitions d ON d.id=i.watcher_id' + where +
                              ' ORDER BY i.created_at DESC,i.rowid DESC LIMIT ?', parameters).fetchall()
            return [dict(row) for row in rows]

    def mark_inbox_read(self, inbox_id, *, request_id=None):
        def action(db):
            if not db.execute('SELECT 1 FROM inbox_items WHERE id=?', (inbox_id,)).fetchone():
                raise WatchersError('inbox_not_found', 'Watcher inbox item not found', status=404)
            db.execute('UPDATE inbox_items SET read_at=coalesce(read_at,?) WHERE id=?', (iso(self.now()), inbox_id))
            return {'id': inbox_id, 'read': True}
        return self._mutate('mark_inbox_read', [inbox_id], request_id, action)

    def mark_all_inbox_read(self, *, request_id=None):
        def action(db):
            count = db.execute('UPDATE inbox_items SET read_at=? WHERE read_at IS NULL', (iso(self.now()),)).rowcount
            return {'read': True, 'count': count}
        return self._mutate('mark_all_inbox_read', [], request_id, action)

    def request_stop(self, run_id, *, request_id=None):
        def action(db):
            row = db.execute('SELECT status FROM runs WHERE id=?', (run_id,)).fetchone()
            if row is None:
                raise WatchersError('run_not_found', 'Watcher run not found', status=404)
            if row['status'] in RUNNING:
                db.execute('UPDATE runs SET stop_requested=1 WHERE id=?', (run_id,))
            return {'run_id': run_id}
        return self._mutate('request_stop', [run_id], request_id, action)

    def set_next_fire(self, watcher_id, value):
        with self.connection(write=True) as db:
            db.execute('UPDATE definitions SET next_fire_at=? WHERE id=?', (iso(value) if value else None, watcher_id))

    def get_metadata(self, key):
        with self.connection() as db:
            row = db.execute('SELECT value FROM metadata WHERE key=?', (key,)).fetchone()
            return row[0] if row else None

    def set_metadata(self, key, value):
        with self.connection(write=True) as db:
            db.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)', (key, value))

    def prune(self, now=None):
        now = instant(now) if now is not None else self.now()
        doomed = []
        with self.connection(write=True) as db:
            for watcher in db.execute('SELECT id FROM definitions').fetchall():
                rows = db.execute("SELECT id,started_at FROM runs WHERE watcher_id=? AND status NOT IN ('queued','running') ORDER BY started_at DESC,rowid DESC", (watcher['id'],)).fetchall()
                # Keep whichever is larger: 30 days OR the most recent 200 runs.
                for row in rows[200:]:
                    if instant(row['started_at']) < now - timedelta(days=30):
                        doomed.append(self.root / watcher['id'] / 'runs' / row['id'])
                        db.execute('DELETE FROM runs WHERE id=?', (row['id'],))
            removed_inbox = db.execute('DELETE FROM inbox_items WHERE created_at<?', (iso(now - timedelta(days=90)),)).rowcount
        for path in doomed:
            shutil.rmtree(path, ignore_errors=True)
        return {'runs': len(doomed), 'inbox_items': removed_inbox}

    def logs(self, run_id, *, step_id=None, stream='stdout'):
        if stream not in ('stdout', 'stderr'):
            raise WatchersError('invalid_request', 'Log stream must be stdout or stderr')
        run = self.get_run(run_id)
        steps = run['step_runs']
        if step_id is None:
            step_id = run['step_id'] or (steps[-1]['step_id'] if steps else None)
        if step_id is not None:
            with self.connection() as db:
                row = db.execute('SELECT snapshot_json FROM runs WHERE id=?', (run_id,)).fetchone()
                if step_id not in [s['id'] for s in json.loads(row[0])['steps']]:
                    raise WatchersError('step_not_found', 'Run step not found', status=404)
        path = self.root / run['watcher_id'] / 'runs' / run_id / 'steps' / str(step_id) / (stream + '.log')
        if not path.is_file():
            return {'content': '', 'stream': stream, 'step_id': step_id, 'truncated': False}
        size = path.stat().st_size
        with path.open('rb') as handle:
            handle.seek(max(0, size - 128 * 1024))
            content = handle.read(128 * 1024).decode('utf-8', errors='replace')
        return {'content': content, 'stream': stream, 'step_id': step_id, 'truncated': size > 128 * 1024}

    def transition_source(self, source, state, *, request_id=None):
        if source != 'cronboard' or state not in ('active', 'paused'):
            raise WatchersError('invalid_request', 'Batch transitions support Cronboard pause and resume')
        def action(db):
            current = 'paused' if state == 'active' else 'active'
            rows = db.execute('SELECT id,definition_json FROM definitions WHERE state=?', (current,)).fetchall()
            return [self._transition(db, row['id'], state, None, None) for row in rows
                    if json.loads(row['definition_json']).get('source', {}).get('kind') == source]
        return self._mutate('transition_source', [source, state], request_id, action)

    def create_edit_draft(self, watcher_id, builder_session_id, *, request_id=None):
        def action(db):
            row = self._row(db, watcher_id)
            original = json.loads(row['definition_json'])
            if original.get('edit_target_id'):
                raise WatchersError('invalid_request', 'Continue the existing edit draft instead')
            bodies = self._scripts(original, None, previous=self.root / watcher_id / f"rev-{row['revision']}")
            value = dict(original)
            value.pop('source', None)
            value.update(state='draft', builder_session_id=builder_session_id, created_by='agent:watcher-builder',
                         edit_target_id=watcher_id, edit_target_revision=row['revision'])
            return self._create(db, value, bodies, 'draft')
        return self._mutate('create_edit_draft', [watcher_id, builder_session_id], request_id, action)

    def apply_edit_draft(self, draft_id, *, request_id=None, confirmed_by=None, activated_via=None):
        def action(db):
            if confirmed_by != 'user':
                raise WatchersError('confirmation_required', 'A person must confirm saving these changes', status=409)
            draft_row = self._row(db, draft_id)
            draft = json.loads(draft_row['definition_json'])
            target_id = draft.get('edit_target_id')
            if not target_id or draft_row['state'] != 'draft':
                raise WatchersError('invalid_state', 'This watcher is not a pending edit', status=409)
            target_row = self._row(db, target_id)
            if target_row['revision'] != draft.get('edit_target_revision'):
                raise WatchersError('revision_conflict', 'The original watcher changed. Start a new edit from its latest revision.', status=409)
            original = json.loads(target_row['definition_json'])
            protected = {'id', 'revision', 'state', 'created_at', 'updated_at', 'activated_by', 'activated_via',
                         'source', 'machine', 'edit_target_id', 'edit_target_revision', 'builder_session_id', 'created_by'}
            value = dict(original)
            value.update({key: item for key, item in draft.items() if key not in protected})
            value['revision'] = target_row['revision'] + 1
            if value['state'] == 'draft':
                value.update(state='active', activated_by='user', activated_via=activated_via or 'watcher-builder')
            value = self._normalize(value)
            bodies = self._scripts(draft, None, previous=self.root / draft_id / f"rev-{draft_row['revision']}")
            from .runtime import validate_executable
            validate_executable(value)
            if any(step['kind'] == 'script' and step['file'] not in bodies for step in value['steps']):
                raise WatchersError('script_missing', 'Every saved script step needs a body', status=409)
            result = self._save(db, value, bodies)
            draft.update(state='done', revision=draft_row['revision'] + 1)
            self._save(db, draft, bodies)
            return result
        return self._mutate('apply_edit_draft', [draft_id, confirmed_by, activated_via], request_id, action)

    def unread_count(self, *, source=None):
        with self.connection() as db:
            if source is None:
                return db.execute('SELECT count(*) FROM inbox_items WHERE read_at IS NULL').fetchone()[0]
            return db.execute("SELECT count(*) FROM inbox_items i JOIN definitions d ON d.id=i.watcher_id WHERE i.read_at IS NULL AND json_extract(d.definition_json,'$.source.kind')=?", (source,)).fetchone()[0]

    @staticmethod
    def _before(value):
        try:
            return iso(value)
        except (TypeError, ValueError, AttributeError):
            raise WatchersError('invalid_request', 'before must be an ISO timestamp') from None

    def prepare_delete(self, watcher_id, *, force=False, request_id=None):
        """Reserve its receipt before stopping anything; replay completed deletes.

        JSON null is an unfinished reservation. A restart can resume that same
        deletion, while a different use of the request id conflicts immediately.
        """
        if request_id is not None and (not isinstance(request_id, str) or not request_id or len(request_id) > 200):
            raise WatchersError('invalid_request', 'request_id must be a nonempty string of at most 200 characters')
        fingerprint = hashlib.sha256(encoded(['delete', [watcher_id, force]]).encode()).hexdigest()
        with self.connection(write=True) as db:
            if request_id:
                receipt = db.execute('SELECT * FROM receipts WHERE request_id=?', (request_id,)).fetchone()
                if receipt:
                    if receipt['fingerprint'] != fingerprint:
                        raise WatchersError('idempotency_conflict', 'request_id was already used for another request', status=409)
                    if receipt['response_json'] != 'null':
                        return json.loads(receipt['response_json'])
            self._row(db, watcher_id)
            if request_id:
                db.execute('INSERT OR IGNORE INTO receipts VALUES(?,?,?,?)', (request_id, fingerprint, 'null', iso(self.now())))
        return None

    def duplicate(self, watcher_id, *, request_id=None):
        def action(db):
            row = self._row(db, watcher_id)
            value = json.loads(row['definition_json'])
            bodies = self._scripts(value, None, previous=self.root / watcher_id / f"rev-{row['revision']}")
            for key in ('source', 'edit_target_id', 'edit_target_revision', 'builder_session_id'):
                value.pop(key, None)
            return self._create(db, value, bodies, 'draft')
        return self._mutate('duplicate', [watcher_id], request_id, action)
