from __future__ import annotations
import fcntl
import signal
import time
from concurrent.futures import ThreadPoolExecutor
from .engine import Horos
from .media import export_study
from .queue import Queue
from .storage import config, data_root, write_json


def scan(engine, queue):
    details = []
    # Inventory is read through Horos's managed-object context, never its database files.
    for study in engine.studies():
        details.append(engine.call("/study", {"id": study["id"]}))
    queue.observe(details, quiet_seconds=config().get("quiet_seconds", 30))
    return queue.overview()


def prepare(job_id, engine=None, queue=None):
    engine = engine or Horos(); queue = queue or Queue()
    token = queue.begin_export(job_id)
    if not token: return
    try:
        job = queue.get(job_id)
        export_study(engine, job["detail"], lambda done, total: queue.update(job_id, rendered=done))
        queue.finish_export(job_id, token)
    except Exception as exc:
        queue.finish_export(job_id, token, type(exc).__name__ + ": " + str(exc)[:500])


def main():
    import os
    os.umask(0o077)
    queue = Queue(); engine = Horos(); stop = False
    def terminate(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, terminate); signal.signal(signal.SIGINT, terminate)
    with (data_root() / "listener.lock").open("a+") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = None
            while not stop:
                try:
                    summary = scan(engine, queue)
                    write_json(data_root() / "listener.json", {"running": True, "checked_at": time.time(), **summary})
                    if future is None or future.done():
                        jobs = queue.jobs(("pending", "exporting"))
                        eligible = next((j for j in jobs if j["state"] == "pending" or (j["expires"] or 0) < time.time()), None)
                        if eligible: future = executor.submit(prepare, eligible["id"], engine, queue)
                except Exception as exc:
                    write_json(data_root() / "listener.json", {"running": True, "checked_at": time.time(), "error": type(exc).__name__ + ": " + str(exc)[:300]})
                for _ in range(10):
                    if stop: break
                    time.sleep(1)
        write_json(data_root() / "listener.json", {"running": False, "checked_at": time.time()})

if __name__ == "__main__": main()
