"""Radiology Agent research reporting API. DICOM is received by Horos or the clinic PACS."""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Annotated, Literal
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field

Tag = Annotated[str, Field(min_length=1, max_length=64)]

class StudyInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    study_uid: str = Field(pattern=r'^[0-9]+(?:\.[0-9]+)*$', max_length=64)
    patient_id: str = Field(default='', max_length=128)
    patient_name: str = Field(default='', max_length=256)
    accession: str = Field(default='', max_length=128)
    description: str = Field(default='', max_length=512)
    modality: str = Field(default='', max_length=16)
    tags: list[Tag] = Field(default_factory=list, max_length=32)
    priority: Literal['routine', 'urgent'] = 'routine'
    assignee: str = Field(default='', max_length=128)
    received_complete: bool = False

class StudyPatch(BaseModel):
    model_config = ConfigDict(extra='forbid')
    status: Literal['new', 'queued', 'draft', 'reviewed'] | None = None
    priority: Literal['routine', 'urgent'] | None = None
    assignee: str | None = Field(default=None, max_length=128)
    tags: list[Tag] | None = Field(default=None, max_length=32)
    expected_revision: int = Field(ge=1)

class TemplateInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(pattern=r'^[a-zA-Z0-9_-]+$', max_length=128)
    name: str = Field(min_length=1, max_length=128)
    modalities: list[str] = Field(default_factory=list, max_length=32)
    keywords: list[str] = Field(default_factory=list, max_length=64)
    document: str = Field(min_length=1, max_length=100000)
    expected_revision: int = Field(default=0, ge=0)

class KeyImageInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(min_length=1, max_length=128)
    phrase: str = Field(min_length=1, max_length=4000)
    imageID: str = Field(max_length=2048)
    imageIndex: int = Field(ge=0)
    studyUID: str = Field(pattern=r'^[0-9]+(?:\.[0-9]+)*$', max_length=64)
    sopInstanceUID: str | None = Field(default=None, pattern=r'^[0-9]+(?:\.[0-9]+)*$', max_length=64)
    frame: int | None = Field(default=None, ge=0)
    windowWidth: float = Field(ge=1, le=1_000_000, allow_inf_nan=False)
    windowCenter: float = Field(ge=-1_000_000, le=1_000_000, allow_inf_nan=False)

class DraftInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    document: str = Field(max_length=200000)
    template_id: str | None = Field(default=None, max_length=128)
    evidence: list[KeyImageInput] = Field(default_factory=list, max_length=300)
    expected_revision: int = Field(ge=0)
    claim_token: str | None = Field(default=None, min_length=32, max_length=128)

class ClaimInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    worker_id: str = Field(min_length=1, max_length=128)
    expected_revision: int = Field(ge=1)

class LeaseInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    claim_token: str = Field(min_length=32, max_length=128)
    failed: bool = False


def create_app(data_dir: Path | None = None, api_token: str | None = None) -> FastAPI:
    root = data_dir or Path(os.environ.get('RADAGENT_BACKEND_DATA', Path.home() / 'Library/Application Support/RadAgent/backend'))
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    token_file = root / 'api-token'
    token = api_token or os.environ.get('RADAGENT_API_TOKEN')
    if not token:
        if not token_file.exists():
            fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as output:
                output.write(secrets.token_urlsafe(40))
        token = token_file.read_text().strip()
    if len(token) < 32:
        raise ValueError('RADAGENT_API_TOKEN must contain at least 32 characters')
    db_file = root / 'worklist.sqlite3'

    @contextmanager
    def db(write=False):
        connection = sqlite3.connect(db_file, timeout=15)
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA foreign_keys=ON')
        try:
            connection.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    with db(write=True) as conn:
        if conn.execute('PRAGMA user_version').fetchone()[0] > 2:
            raise RuntimeError('This database was created by a newer Radiology Agent version')
        conn.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS studies(uid TEXT PRIMARY KEY, payload TEXT NOT NULL, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS templates(id TEXT PRIMARY KEY, payload TEXT NOT NULL, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS drafts(uid TEXT PRIMARY KEY REFERENCES studies(uid), payload TEXT NOT NULL, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS draft_versions(uid TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(uid, revision));
        CREATE TABLE IF NOT EXISTS receipts(key TEXT PRIMARY KEY, digest TEXT NOT NULL, response TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, action TEXT NOT NULL, resource TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS studies_worklist ON studies(json_extract(payload, '$.status'), json_extract(payload, '$.priority'), json_extract(payload, '$.received_at'));
        PRAGMA user_version=2;
        ''')
    db_file.chmod(0o600)
    app = FastAPI(title='Radiology Agent Research Reporting API', version='0.5.0', description='Worklist, templates, and evaluation drafts. No report signing or clinical finalization.', docs_url=None, redoc_url=None, openapi_url=None)
    bearer = HTTPBearer(auto_error=False)

    def auth(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if credentials is None or not hmac.compare_digest(credentials.credentials.encode('utf-8'), token.encode('utf-8')):
            raise HTTPException(401, 'Bearer token required', headers={'WWW-Authenticate': 'Bearer'})

    @app.middleware('http')
    async def limits(request: Request, call_next):
        from starlette.responses import JSONResponse
        if request.headers.get('origin'):
            return JSONResponse({'detail': 'Browser origins are not supported'}, status_code=403)
        try:
            if int(request.headers.get('content-length', '0')) > 1_000_000:
                return JSONResponse({'detail': 'Request too large'}, status_code=413)
        except ValueError:
            return JSONResponse({'detail': 'Invalid content length'}, status_code=400)
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > 1_000_000:
                return JSONResponse({'detail': 'Request too large'}, status_code=413)
        request._body = bytes(body)
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        return response

    def audit(conn, action, resource):
        conn.execute('INSERT INTO audit(time,action,resource) VALUES(?,?,?)', (time.time(), action, resource))

    def read(conn, table, key):
        column = 'id' if table == 'templates' else 'uid'
        row = conn.execute(f'SELECT payload, revision FROM {table} WHERE {column}=?', (key,)).fetchone()
        if not row:
            raise HTTPException(404, 'Resource not found')
        return json.loads(row['payload']) | {'revision': row['revision']}

    @app.get('/health')
    def health():
        return {'status': 'ok', 'version': '0.5.0'}

    @app.get('/openapi.json', dependencies=[Depends(auth)])
    def schema():
        return app.openapi()

    @app.post('/v1/studies', dependencies=[Depends(auth)])
    def receive_study(study: StudyInput, idempotency_key: str | None = Header(default=None, max_length=200)):
        value = study.model_dump()
        if any(len(tag) > 64 for tag in value['tags']):
            raise HTTPException(422, 'Tags must be at most 64 characters')
        digest = hashlib.sha256(json.dumps(study.model_dump(exclude_unset=True), sort_keys=True).encode()).hexdigest()
        with db(write=True) as conn:
            if idempotency_key:
                receipt = conn.execute('SELECT * FROM receipts WHERE key=?', (idempotency_key,)).fetchone()
                if receipt:
                    if receipt['digest'] != digest:
                        raise HTTPException(409, 'Idempotency key reused with different content')
                    return json.loads(receipt['response'])
            previous = conn.execute('SELECT payload,revision FROM studies WHERE uid=?', (study.study_uid,)).fetchone()
            revision = previous['revision'] + 1 if previous else 1
            old = json.loads(previous['payload']) if previous else {}
            if old.get('patient_id') and 'patient_id' in study.model_fields_set and old['patient_id'] != study.patient_id:
                raise HTTPException(409, 'Study UID already belongs to a different patient')
            for key in value:
                if key not in study.model_fields_set and key in old:
                    value[key] = old[key]
            value.update(status=old.get('status', 'new'), received_at=old.get('received_at', time.time()), updated_at=time.time())
            value.update({key: old[key] for key in ('claimed_by', 'lease_expires', 'claim_token') if key in old})
            if value['status'] == 'new' and value['received_complete'] and 'radagent-draft' in value['tags']:
                value['status'] = 'queued'
            conn.execute('INSERT INTO studies VALUES(?,?,?) ON CONFLICT(uid) DO UPDATE SET payload=excluded.payload,revision=excluded.revision', (study.study_uid, json.dumps(value), revision))
            result = value | {'revision': revision}
            if idempotency_key:
                conn.execute('INSERT INTO receipts VALUES(?,?,?)', (idempotency_key, digest, json.dumps(result)))
            audit(conn, 'study.received', study.study_uid)
            return result

    @app.get('/v1/studies', dependencies=[Depends(auth)])
    def list_studies(offset: int = 0, limit: int = 100, status: str | None = None):
        if offset < 0 or not 1 <= limit <= 500:
            raise HTTPException(422, 'Invalid pagination')
        where = " WHERE json_extract(payload, '$.status')=?" if status is not None else ''
        parameters = (status,) if status is not None else ()
        with db() as conn:
            total = conn.execute('SELECT COUNT(*) FROM studies' + where, parameters).fetchone()[0]
            records = conn.execute('SELECT * FROM studies' + where + " ORDER BY (json_extract(payload, '$.priority')='urgent') DESC, json_extract(payload, '$.received_at') DESC, uid LIMIT ? OFFSET ?", parameters + (limit, offset))
            rows = [json.loads(row['payload']) | {'revision': row['revision']} for row in records]
        for row in rows:
            row.pop('claim_token', None)
        return {'studies': rows, 'total': total}

    @app.patch('/v1/studies/{uid}', dependencies=[Depends(auth)])
    def update_study(uid: str, patch: StudyPatch):
        with db(write=True) as conn:
            value = read(conn, 'studies', uid)
            if value.pop('revision') != patch.expected_revision:
                raise HTTPException(409, 'Study changed; refresh before updating')
            value.update(patch.model_dump(exclude_none=True, exclude={'expected_revision'}))
            value['updated_at'] = time.time()
            revision = patch.expected_revision + 1
            conn.execute('UPDATE studies SET payload=?,revision=? WHERE uid=?', (json.dumps(value), revision, uid))
            audit(conn, 'study.updated', uid)
            return value | {'revision': revision}

    @app.post('/v1/studies/{uid}/claim', dependencies=[Depends(auth)])
    def claim(uid: str, claim: ClaimInput):
        with db(write=True) as conn:
            value = read(conn, 'studies', uid)
            if value.pop('revision') != claim.expected_revision:
                raise HTTPException(409, 'Study changed before claim')
            eligible = value['status'] == 'queued' or (value['status'] == 'processing' and value.get('lease_expires', 0) < time.time())
            if not eligible or not value.get('received_complete') or 'radagent-draft' not in value['tags']:
                raise HTTPException(409, 'Study is not available for an automatic draft')
            value.update(status='processing', claimed_by=claim.worker_id, lease_expires=time.time() + 1800, claim_token=secrets.token_urlsafe(32))
            revision = claim.expected_revision + 1
            conn.execute('UPDATE studies SET payload=?,revision=? WHERE uid=?', (json.dumps(value), revision, uid))
            audit(conn, 'study.claimed', uid)
            return value | {'revision': revision}

    @app.post('/v1/studies/{uid}/lease', dependencies=[Depends(auth)])
    def renew_lease(uid: str, lease: LeaseInput):
        with db(write=True) as conn:
            value = read(conn, 'studies', uid)
            if value['status'] != 'processing' or value.get('lease_expires', 0) <= time.time() or not hmac.compare_digest(lease.claim_token, value.get('claim_token', '')):
                raise HTTPException(409, 'Draft lease is expired or owned by another worker')
            revision = value.pop('revision') + 1
            value['lease_expires'] = time.time() + 1800
            conn.execute('UPDATE studies SET payload=?,revision=? WHERE uid=?', (json.dumps(value), revision, uid))
            audit(conn, 'study.lease_renewed', uid)
            return {'lease_expires': value['lease_expires'], 'revision': revision}

    @app.delete('/v1/studies/{uid}/lease', dependencies=[Depends(auth)])
    def release_lease(uid: str, lease: LeaseInput):
        with db(write=True) as conn:
            value = read(conn, 'studies', uid)
            if value['status'] != 'processing' or not hmac.compare_digest(lease.claim_token, value.get('claim_token', '')):
                raise HTTPException(409, 'Draft lease is owned by another worker or already completed')
            revision = value.pop('revision') + 1
            value.update(status='attention' if lease.failed else 'queued', updated_at=time.time())
            for key in ('claim_token', 'claimed_by', 'lease_expires'):
                value.pop(key, None)
            conn.execute('UPDATE studies SET payload=?,revision=? WHERE uid=?', (json.dumps(value), revision, uid))
            audit(conn, 'study.draft_failed' if lease.failed else 'study.requeued', uid)
            return {'status': value['status'], 'revision': revision}

    @app.get('/v1/templates', dependencies=[Depends(auth)])
    def templates():
        with db() as conn:
            return {'templates': [json.loads(row['payload']) | {'revision': row['revision']} for row in conn.execute('SELECT * FROM templates ORDER BY id')]}

    @app.put('/v1/templates/{template_id}', dependencies=[Depends(auth)])
    def put_template(template_id: str, template: TemplateInput):
        if template_id != template.id:
            raise HTTPException(422, 'Template ID mismatch')
        with db(write=True) as conn:
            row = conn.execute('SELECT revision FROM templates WHERE id=?', (template_id,)).fetchone()
            if (row['revision'] if row else 0) != template.expected_revision:
                raise HTTPException(409, 'Template changed; refresh before updating')
            revision = template.expected_revision + 1
            value = template.model_dump(exclude={'expected_revision'})
            conn.execute('INSERT OR REPLACE INTO templates VALUES(?,?,?)', (template_id, json.dumps(value), revision))
            audit(conn, 'template.saved', template_id)
            return value | {'revision': revision}

    @app.get('/v1/studies/{uid}/draft', dependencies=[Depends(auth)])
    def draft(uid: str):
        with db() as conn:
            return read(conn, 'drafts', uid)

    @app.put('/v1/studies/{uid}/draft', dependencies=[Depends(auth)])
    def put_draft(uid: str, draft: DraftInput):
        if len({reference.id for reference in draft.evidence}) != len(draft.evidence):
            raise HTTPException(422, 'Evidence IDs must be unique')
        if any(reference.studyUID != uid or draft.document.count(reference.phrase) != 1 for reference in draft.evidence):
            raise HTTPException(422, 'Each evidence reference must match this study and one unique report phrase')
        with db(write=True) as conn:
            study = read(conn, 'studies', uid)
            if draft.claim_token is not None or study['status'] == 'processing':
                if study['status'] != 'processing' or study.get('lease_expires', 0) <= time.time() or not draft.claim_token or not hmac.compare_digest(draft.claim_token, study.get('claim_token', '')):
                    raise HTTPException(409, 'Automatic draft lease is missing, expired, or owned by another worker')
            row = conn.execute('SELECT revision FROM drafts WHERE uid=?', (uid,)).fetchone()
            if (row['revision'] if row else 0) != draft.expected_revision:
                raise HTTPException(409, 'Draft changed; refresh before saving')
            value = draft.model_dump(exclude={'expected_revision', 'claim_token'}) | {'purpose': 'Draft for evaluation', 'updated_at': time.time()}
            revision = draft.expected_revision + 1
            conn.execute('INSERT OR REPLACE INTO drafts VALUES(?,?,?)', (uid, json.dumps(value), revision))
            conn.execute('INSERT INTO draft_versions VALUES(?,?,?)', (uid, revision, json.dumps(value)))
            study_revision = study.pop('revision') + 1
            study.update(status='draft', updated_at=time.time())
            for key in ('claim_token', 'claimed_by', 'lease_expires'):
                study.pop(key, None)
            conn.execute('UPDATE studies SET payload=?,revision=? WHERE uid=?', (json.dumps(study), study_revision, uid))
            audit(conn, 'draft.saved', uid)
            return value | {'revision': revision}

    @app.get('/v1/studies/{uid}/draft/versions', dependencies=[Depends(auth)])
    def draft_versions(uid: str):
        with db() as conn:
            return {'versions': [json.loads(row['payload']) | {'revision': row['revision']} for row in conn.execute('SELECT * FROM draft_versions WHERE uid=? ORDER BY revision DESC', (uid,))]}

    @app.get('/v1/audit', dependencies=[Depends(auth)])
    def audit_events(after: int = 0):
        with db() as conn:
            return {'events': [dict(row) for row in conn.execute('SELECT * FROM audit WHERE seq>? ORDER BY seq LIMIT 500', (max(0, after),))]}

    return app
