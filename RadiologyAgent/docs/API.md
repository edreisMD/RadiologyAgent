# Clinic API integration

Base URL for a local installation: `http://127.0.0.1:8043`. All `/v1` routes and `/openapi.json` require `Authorization: Bearer <clinic-token>`. `/health` exposes only service status/version. Browser origins are rejected. The clinic token is distinct from the OpenAI key.

The API receives worklist metadata. It is **not** a DICOM STOW-RS endpoint or a DICOM modality worklist SCP. Send DICOM to Horos/PACS by the clinic's normal DICOM connection. The app joins worklist entries to images using `StudyInstanceUID`, never patient name.

## Study arrival

`POST /v1/studies` accepts:

```json
{
  "study_uid": "1.2.840.113619.2.1",
  "patient_id": "RESEARCH-001",
  "patient_name": "Synthetic API fixture",
  "accession": "EVAL-001",
  "description": "Chest radiograph",
  "modality": "CR",
  "tags": ["radagent-draft"],
  "priority": "routine",
  "assignee": "",
  "received_complete": true
}
```

Use an `Idempotency-Key` header for each upstream event. Repeating the same event returns its original response; reusing its key with different content returns 409. The same study UID cannot be reassigned to a different nonempty patient ID. Partial updates preserve omitted metadata. `received_complete` is the upstream system's arrival/stability signal; it does not certify exam completeness.

`radagent-draft` plus `received_complete: true` transitions a new study to `queued`. A row remains **Awaiting images** in the app until the matching DICOM study is present in Horos. No report is generated merely because a patient name matches.

## Endpoints

| Method | Route | Purpose |
|---|---|---|
| GET | `/v1/studies?offset=0&limit=100` | Paginated worklist; optional `status` filter |
| POST | `/v1/studies` | Idempotent study arrival/upsert |
| PATCH | `/v1/studies/{uid}` | Status, priority, assignee, or tags; requires `expected_revision` |
| POST | `/v1/studies/{uid}/claim` | Atomic draft claim using `worker_id` and `expected_revision` |
| POST | `/v1/studies/{uid}/lease` | Renew an unexpired automatic claim with `claim_token` |
| DELETE | `/v1/studies/{uid}/lease` | Release own claim; `failed: true` moves it to attention |
| GET | `/v1/templates` | Shared template catalog |
| PUT | `/v1/templates/{id}` | Versioned template create/update |
| GET | `/v1/studies/{uid}/draft` | Latest evaluation draft |
| PUT | `/v1/studies/{uid}/draft` | Save document and evidence with `expected_revision` |
| GET | `/v1/studies/{uid}/draft/versions` | Preserved versions |
| GET | `/v1/audit?after=0` | Audit events with sequence cursors |
| GET | `/openapi.json` | Generated machine-readable API schema |

A draft save has `document`, optional `template_id`, `evidence`, and `expected_revision` (0 for the first save). Every response is marked **Draft for evaluation**. There is no finalization/signature endpoint. A stale expected revision returns 409; clients must refresh and reconcile before saving.

Evidence records contain an exact unique `phrase`, `studyUID`, `sopInstanceUID`, `frame`, local fallback `imageID`, `imageIndex`, `windowWidth`, `windowCenter`, and an `id`. Multiple images can reference the same phrase. The app resolves portable references by Study/SOP UID and frame rather than trusting a foreign workstation's local image index.

Template bodies contain `id`, `name`, `modalities`, `keywords`, `document`, and `expected_revision` (0 when new). They contain editable text/section headings rather than executable HTML. Original sample templates use placeholders, not assumed normal findings.

## Orthanc bridge

`backend/integrations/orthanc_bridge.py` follows Orthanc's changes log, reads `StableStudy` events, and forwards only studies labelled `radagent-draft`. It persists its cursor after each successfully handled event. Failed forwarding leaves the cursor for retry. If `ORTHANC_HOROS_MODALITY` is configured, it first routes the study through Orthanc's existing DICOM modality connection.

Environment variables:

- `ORTHANC_URL`: HTTPS or a loopback HTTP URL.
- `ORTHANC_USER` and `ORTHANC_PASSWORD`: credentials, when required by Orthanc.
- `ORTHANC_HOROS_MODALITY`: optional configured Orthanc modality name for Horos.
- `RADAGENT_BACKEND_URL` and `RADAGENT_BACKEND_TOKEN`: reporting service connection.
- `RADAGENT_BRIDGE_STATE`: optional private cursor file path.

Run with `.venv/bin/python -m backend.integrations.orthanc_bridge`. Configure DICOM routing/listeners separately. No Orthanc host, credential, or clinic DICOM destination is embedded in the source.

## Automatic draft ownership (0.5)

`POST /v1/studies/{uid}/claim` returns `claim_token` and `lease_expires`. The worker must include that token as `claim_token` when saving its automatic draft. Expired, superseded, or missing tokens return 409 while a study is processing. Ordinary worklist listings omit the claim token. Manual draft saves do not require a token when the study is not processing. Draft revisions still protect against stale manual saves.

Upgrade the backend and desktop together. Existing 0.3 in-flight claims need to expire before they can be reclaimed by a 0.4 worker. SQLite schema version 2 adds a worklist index; newer unknown database versions are rejected without downgrading them.

Native Horos intake registers every newly observed UID automatically. It sets `received_complete` after its local quiet-period and inventory checks and adds `horos-arrival` and `radagent-draft`; this is an arrival heuristic. Existing priority, assignee and other tags are preserved. The desktop renews its claim before each model request. Release returns the job to `queued`, or `attention` after exhausted retries. An operator can requeue an attention entry with an optimistic PATCH. A saved draft cannot be released or overwritten by an expired worker.
