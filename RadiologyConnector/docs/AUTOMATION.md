# Incoming-study dispatcher

Not for medical use, research only.

Install the listener with `--listener`. Creating a schedule is a separate action and requires the user's request. Use Codex's supported automation tool to create one thread heartbeat, for example every minute. Do not write a system cron job or start a hidden model process.

Use this dispatcher prompt:

> Check the Radiology Connector incoming-study queue. Act only as dispatcher. Call study_runs first. Reconcile unresolved reservations by finding the existing Codex task with the exact unique title and confirming its initial prompt contains the exact job ID; attach it with recover_study_run. Never create a duplicate after an uncertain result. Call reserve_study_run for newly ready studies only. When reserved=true, call create_thread with the returned title, prompt and model, using a projectless target, then attach_study_run with the returned threadId and reservation token. Do not use a clientThreadId. The connector limits active study tasks to two. Do not backfill historical studies, draft in this dispatcher, or create another schedule. Each child reads all available images, writes an English unsigned Draft for evaluation in the shared report pane, includes “Not for medical use, research only.”, renders and checks the Word document, then publishes it to the configured folder. Stay quiet on an empty or unchanged queue and report failures once.

The fallback `plugins/horos-connector/scripts/dispatch.py` accepts JSON on stdin with `status`, `reserve`, `attach`, or `recover` operations for an older Codex task that lacks refreshed MCP tools. It does not create Codex tasks itself.

If task creation is uncertain, preserve the reservation and reconcile it. Never release it and retry blindly. Study arrival stability is an operational heuristic and does not prove clinical completeness.
