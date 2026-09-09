# Automatic incoming-study drafting

Radiology Agent owns the arrival queue; Horos owns DICOM storage and decoding. No screenshot import, second viewer window, cron task, or external connector is required.

1. The first complete Horos scan establishes a baseline. Existing studies are listed but are not automatically redrafted.
2. Each subsequent scan adds new Study Instance UIDs to the worklist. Old acquisition dates do not exclude newly received studies. The UID and patient identity are checked independently of patient name.
3. A study with images waits for 60 seconds of unchanged image count. Two full inventories, at least 15 seconds apart, must agree on series UID, SOP UID/frame and dimensions. Missing images, an outage, or changed inventory resets readiness. This is a quiet-period heuristic; Horos does not provide a verified exam-completion signal through this integration.
4. One background session at a time chooses a template and requests native DICOM renderings. The session is independent of the radiologist’s selected study, slice and report editor. It uses a maximum of 64 model turns, with batches of up to 12 images, and stops automatically after three failed model attempts with exponential backoff.
5. The frame inventory is checked again before delivery. The candidate is stored durably before it is placed in the workspace or sent to the optional clinic API. A completed candidate is reused after an interrupted save instead of generating another report. A terminated in-flight model request may be repeated on recovery; API execution itself is not exactly-once.
6. A generated report remains **Draft for evaluation**. Key-image links must resolve to frames actually reviewed in that session. The recorded coverage counts unique reviewed frames. Incomplete review, patient identity conflicts, additional images after a draft, and concurrent report edits produce **Needs attention**. Full frame coverage does not establish diagnostic accuracy.

## Worklist controls

**Draft new studies automatically** is enabled for a new queue. Switching it off pauses new model jobs; intake continues and a running job finishes. Right-click a failed row to retry. Right-click an existing unreported row to queue it explicitly. Paused arrivals remain queued for when drafting is enabled again.

A study’s status tooltip contains the failure or coverage detail. Completed drafts appear under Drafts. If the radiologist edits a report while an automatic draft is being prepared, the current report is preserved and the automatic candidate is put in History. A candidate with changed image inventory remains in the private journal for recovery and must not be treated as current.

## Process lifetime and persistence

The monitor runs while the Radiology Agent process is running, even after its window is closed. Click the Dock icon to reopen it. Quit stops monitoring. Launching again detects studies received since the previous baseline and resumes unfinished work. There is no installed background daemon or automatic login item in this release.

`~/Library/Application Support/RadAgent/incoming-studies.json` stores baseline UIDs, arrival observations, job states and completed candidates. It is atomically saved with owner-only permissions. An advisory process lock prevents two copies of Radiology Agent sharing this workspace from executing the same queue. A corrupt/unwritable journal pauses automatic work and is preserved; the app never silently replaces it with an empty queue.

## Optional clinic service

With no clinic token configured, drafts stay on the Mac. With a configured clinic connection, new study metadata is registered automatically and a model run waits for the service to be available. Atomic claims and renewable 30-minute leases coordinate workstations. Only the current owner can save its automatic draft. An uncertain save is reconciled with the remote draft before retrying. Existing reports, externally supplied priority/assignee, and unrelated tags are preserved.

An unavailable model, Horos, or clinic connection is visible in the worklist. Keep the clinic service supervised if unattended operation is required. Upgrade the desktop and API together to version 0.5 for lease endpoints.

## Verification and limits

Automated tests cover baseline versus new arrival, burst arrivals, inventory replacement, offline gaps, durable recovery, retry limits, identity collisions, actual image-tool output shape, unviewed evidence rejection, partial coverage, and expired/superseded clinic claims. Native rendering and a complete PACS-to-Horos arrival should also be exercised at the deployment site with research fixtures. No tests establish clinical validation.

Large studies may exceed model context or the turn budget and need further review. Native renders are shared with interactive Horos work and may compete for resources. Pixel transport and viewer prefetching remain a separate performance project; this feature does not remove the existing per-frame viewer rendering round trip.
