from __future__ import annotations
from contextlib import contextmanager
import json
import os
import secrets
import sqlite3
import time
from .storage import data_root, digest
from .engine import fingerprint

class Queue:
    def __init__(self, path=None):
        self.path = path or data_root() / "worklist.sqlite3"
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS observed (uid TEXT PRIMARY KEY, revision TEXT NOT NULL, detail TEXT NOT NULL, stable_since REAL NOT NULL, baseline INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, uid TEXT NOT NULL, revision TEXT NOT NULL, detail TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, lease TEXT, expires REAL, error TEXT, report_path TEXT, reviewed TEXT NOT NULL DEFAULT '[]', rendered INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0, UNIQUE(uid,revision));
            ''')
        os.chmod(self.path, 0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=30); db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL"); db.execute("PRAGMA busy_timeout=30000")
        try:
            with db: yield db
        finally: db.close()

    def initialized(self):
        with self.db() as db: return db.execute("SELECT 1 FROM settings WHERE key='initialized'").fetchone() is not None

    def observe(self, details, now=None, quiet_seconds=30):
        now = time.time() if now is None else now
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            initial = db.execute("SELECT 1 FROM settings WHERE key='initialized'").fetchone() is None
            for detail in details:
                uid = detail["study"]["studyUID"]; revision = fingerprint(detail)
                if not uid: continue
                old = db.execute("SELECT * FROM observed WHERE uid=?", (uid,)).fetchone()
                if not old or old["revision"] != revision:
                    db.execute("INSERT OR REPLACE INTO observed VALUES(?,?,?,?,?)", (uid, revision, json.dumps(detail), now, int(initial)))
                elif not old["baseline"] and detail["frameCount"] > 0 and now-old["stable_since"] >= quiet_seconds:
                    self._enqueue(db, detail, now)
            db.execute("INSERT OR REPLACE INTO settings VALUES('initialized', 'true')")
            db.execute("INSERT OR REPLACE INTO settings VALUES('last_scan', ?)", (str(now),))

    def _enqueue(self, db, detail, now):
        uid = detail["study"]["studyUID"]; revision = fingerprint(detail); job_id = digest([uid, revision])[:32]
        db.execute("INSERT OR IGNORE INTO jobs(id,uid,revision,detail,state,created,updated,total) VALUES(?,?,?,?,?,?,?,?)", (job_id, uid, revision, json.dumps(detail), "pending", now, now, detail["frameCount"]))
        return job_id

    def enqueue(self, detail):
        with self.db() as db: return self._enqueue(db, detail, time.time())

    def get(self, job_id):
        with self.db() as db: row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row: raise ValueError("Unknown worklist job.")
        result = dict(row); result["detail"] = json.loads(result["detail"]); result["reviewed"] = json.loads(result["reviewed"])
        return result

    def jobs(self, states=("ready", "processing", "pending", "exporting", "error")):
        with self.db() as db:
            rows = db.execute("SELECT id FROM jobs WHERE state IN ("+",".join("?" for _ in states)+") ORDER BY created", states).fetchall()
        return [self.get(row["id"]) for row in rows]

    def update(self, job_id, **values):
        if not set(values) <= {"state", "error", "rendered", "report_path"}: raise ValueError("Invalid job update")
        with self.db() as db:
            db.execute("UPDATE jobs SET "+",".join(k+"=?" for k in values)+", updated=? WHERE id=?", [*values.values(), time.time(), job_id])

    def claim(self, job_id):
        now = time.time(); token = secrets.token_hex(24)
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if not row or not (row["state"] == "ready" or (row["state"] == "processing" and (row["expires"] or 0)<now)):
                raise ValueError("Job is not ready or is already claimed.")
            db.execute("UPDATE jobs SET state='processing',lease=?,expires=?,updated=? WHERE id=?", (token, now+1800, now, job_id))
        return {"job_id": job_id, "claim_token": token, "lease_expires": now+1800}

    def authorize(self, job_id, token, db=None):
        row = self.get(job_id) if db is None else db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row or row["state"] != "processing" or not secrets.compare_digest(row["lease"] or "", token) or (row["expires"] or 0)<time.time():
            raise ValueError("Claim is missing, expired, or belongs to another worker.")
        return row

    def renew(self, job_id, token):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE"); self.authorize(job_id, token, db)
            db.execute("UPDATE jobs SET expires=? WHERE id=?", (time.time()+1800, job_id))
        return {"renewed": True}

    def record_review(self, job_id, token, indices):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE"); row = self.authorize(job_id, token, db)
            reviewed = sorted(set(json.loads(row["reviewed"])) | set(indices))
            db.execute("UPDATE jobs SET reviewed=? WHERE id=?", (json.dumps(reviewed), job_id))

    def complete(self, job_id, token, path):
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE"); self.authorize(job_id, token, db)
            db.execute("UPDATE jobs SET state='drafted',report_path=?,lease=NULL,expires=NULL,updated=? WHERE id=?", (str(path), time.time(), job_id))

    def overview(self):
        with self.db() as db:
            counts = {r["state"]: r["n"] for r in db.execute("SELECT state,count(*) n FROM jobs GROUP BY state")}
            last = db.execute("SELECT value FROM settings WHERE key='last_scan'").fetchone()
        return {"counts": counts, "last_scan": float(last[0]) if last else None, "baseline_initialized": self.initialized()}

    def begin_export(self, job_id):
        now = time.time(); token = secrets.token_hex(24)
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if not row or not (row["state"] == "pending" or (row["state"] == "exporting" and (row["expires"] or 0) < now)): return None
            db.execute("UPDATE jobs SET state='exporting',lease=?,expires=?,updated=? WHERE id=?", (token, now+3600, now, job_id))
        return token

    def finish_export(self, job_id, token, error=None):
        with self.db() as db:
            db.execute("UPDATE jobs SET state=?,error=?,lease=NULL,expires=NULL,updated=? WHERE id=? AND state='exporting' AND lease=?", ("error" if error else "ready", error, time.time(), job_id, token))
