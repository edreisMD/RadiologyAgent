"""Durable outbox for one Codex desktop task per incoming study revision.

Task creation is performed by Codex's supported create_thread tool. Reserving first
prevents duplicate tasks; uncertain creation is reconciled, never blindly retried.
"""
from __future__ import annotations
import secrets
import time
from .queue import Queue
from .storage import component


class Dispatcher:
    def __init__(self, queue=None):
        self.queue=queue or Queue()
        with self.queue.db() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS codex_runs (
                job_id TEXT PRIMARY KEY REFERENCES jobs(id), token TEXT NOT NULL,
                state TEXT NOT NULL, title TEXT NOT NULL, created REAL NOT NULL,
                thread_id TEXT UNIQUE, error TEXT)''')

    def list_runs(self):
        with self.queue.db() as db:
            return [dict(r) for r in db.execute("SELECT job_id,state,title,created,thread_id,error FROM codex_runs ORDER BY created DESC LIMIT 200")]

    def reserve(self, job_id=None, allow_preparing=False):
        if allow_preparing and not job_id:raise ValueError("A manual preparing-study run requires an exact job ID.")
        with self.queue.db() as db:
            db.execute("BEGIN IMMEDIATE")
            active=db.execute("SELECT count(*) FROM codex_runs r JOIN jobs j ON j.id=r.job_id WHERE j.state NOT IN ('drafted','error')").fetchone()[0]
            if active>=2: return {"reserved":False,"reason":"Two study runs are already active."}
            row=db.execute("SELECT j.id,j.detail FROM jobs j LEFT JOIN codex_runs r ON r.job_id=j.id WHERE (j.state='ready' OR (? AND j.state IN ('pending','exporting'))) AND r.job_id IS NULL AND (? IS NULL OR j.id=?) ORDER BY j.created LIMIT 1",(allow_preparing,job_id,job_id)).fetchone()
            if not row:return {"reserved":False,"reason":"No undispatched ready study."}
            import json
            detail=json.loads(row["detail"])
            from .privacy import public_study
            title="Draft for evaluation · "+component(public_study(detail["study"])["patientName"],limit=60)+" · "+row["id"][:8]
            token=secrets.token_hex(24)
            db.execute("INSERT INTO codex_runs(job_id,token,state,title,created) VALUES(?,?,'reserved',?,?)",(row["id"],token,title,time.time()))
        return {"reserved":True,"job_id":row["id"],"reservation_token":token,"title":title,
                "model":"gpt-6-astra", "prompt":self.prompt(row["id"])}

    @staticmethod
    def prompt(job_id):
        return f"""Use the installed horos-connector plugin and horos-research skill for incoming worklist job {job_id}. This is a separate Codex run for one study, authorized by the radiologist. Use GPT-6 Astra in Codex; do not launch a separate model API client.

Read this exact job with study_media. If its media is still preparing, allow the listener to finish and check again without busy polling; do not duplicate preparation. Once ready, claim it with claim_study and resolve its identity and all series. Open its shared Radiology Agent workspace with open_workspace and show the returned URL in this task's right Codex browser panel using open_in_codex. Do not navigate or open a panel in another task. Use inspect_view for each image and window you review: it returns the same viewport displayed to the radiologist and records full-frame delivery when appropriate. Short notes explain what you are inspecting without inventing a conclusion. The radiologist may temporarily take control; respect that and never force follow mode. Review all local frames; renew the claim during long studies. Exported videos and thumbnails alone do not establish review. Never infer findings from filenames, metadata, templates, or prior draft text.

Choose the appropriate report template, then write a coherent English unsigned report headed Draft for evaluation. Include the exact sentence: Not for medical use, research only. Call update_workspace_report with the complete document and exact phrase-to-image links for supported findings, using the current document revision. Preserve and reconcile any radiologist edits. Use English headings and prose even when source metadata or templates are in Portuguese. If demo display aliases are enabled, use those patient and series aliases in user-visible output; do not repeat original identifying metadata. State partial review and limitations explicitly when applicable. Prepare the Word draft, use the Documents skill to render it and visually inspect every page, and publish it through publish_report to the configured Google Drive sync folder under Patient name - Patient ID. Never sign, finalize, or send to a clinical reporting system. In this Codex conversation, show the completed evaluation draft and the Word file link, so report text stays alongside the viewer. Do not dispatch additional studies or create another schedule. If blocked, describe the failure and retain this task for recovery; do not create a duplicate task."""

    def attach(self,job_id,reservation_token,thread_id):
        import re
        if not re.fullmatch(r"[a-f0-9-]{36}",thread_id):raise ValueError("Use a completed Codex threadId, not a clientThreadId.")
        with self.queue.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row=db.execute("SELECT * FROM codex_runs WHERE job_id=?",(job_id,)).fetchone()
            if not row or not secrets.compare_digest(row["token"],reservation_token):raise ValueError("Invalid reservation.")
            if row["thread_id"] and row["thread_id"]!=thread_id:raise ValueError("This study already has a different Codex task.")
            db.execute("UPDATE codex_runs SET state='started',thread_id=? WHERE job_id=?",(thread_id,job_id))
        return {"job_id":job_id,"thread_id":thread_id,"attached":True}

    def recover(self,job_id,thread_id):
        """Attach a discovered task after an uncertain creation result; never launches one."""
        with self.queue.db() as db:
            row=db.execute("SELECT token FROM codex_runs WHERE job_id=? AND state='reserved'",(job_id,)).fetchone()
        if not row:raise ValueError("No unresolved reservation.")
        return self.attach(job_id,row["token"],thread_id)
