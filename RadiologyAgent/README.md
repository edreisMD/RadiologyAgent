# Radiology Agent

This component builds the Mac app using the shared viewer in `../RadiologyConnector`. From a fresh checkout, run `npm ci --prefix ../RadiologyConnector/horos_connector/web` before `bash scripts/build.sh`.

**Not for medical use, research only.**

Version 0.6 opens a shared DICOM viewer and report workspace in the Mac app and Codex’s right browser panel. Codex is the agent; Horos supplies native DICOM/PACS access and Cornerstone3D renders the images. See [Shared Codex workspace](docs/CODEX_WORKSPACE.md) and the [connector installation guide](../RadiologyConnector/README.md).

The sections below describe the earlier native interface, available from the Study menu. Its automatic API-model worker does not start in parallel with the Codex workflow.

A native macOS workspace for radiologists: conversation, DICOM images, and a document-style **Draft for evaluation**. Horos supplies the imaging engine. An optional clinic API supplies incoming worklists, shared templates, and versioned drafts.

**Research release 0.5.0.** This is an evaluation workflow with no signing, finalization, or report-submission tool. It has not been clinically validated or notarized for general distribution.

## What works

- Browse the existing Horos database and see new studies appear in a worklist that refreshes every 15 seconds.
- Load all locally available series and frames. Horos decodes DICOM and applies window/level; no screenshot import is required.
- Use native mouse controls for window/level, pan, zoom, and scrolling within a series. Pinch zooms around the pointer; double-click fits the image.
- Click thumbnails to inspect images **inside Radiology Agent**. **Open in Horos** or a double-click on the displayed image opens the full native viewer for measurements and advanced manipulation.
- Ask GPT-6 Astra to review images, dictate findings, or revise the report. The default connection loads from a local `.env`; Settings provides an optional Keychain override.
- Edit one continuous report document. Import template text from Word, RTF, Markdown, or text files, and match templates by modality and study description. Templates can be shared through the clinic API.
- Hover an underlined report phrase to preview its key image; click to pin it. **Key image 1/2** steps through multiple images linked to the same phrase. References retain Study/SOP Instance UIDs, frame numbers, and window settings.
- Push studies into the authenticated API, track incoming/queued/draft/reviewed states, and preserve report versions. Optimistic revisions reject conflicting saves.
- Connect an Orthanc arrival feed. A `radagent-draft` label and a stable-study event can queue an evaluation draft; original DICOM reaches Horos through the existing DICOM connection.

## Run on this Mac

Open `dist/Radiology Agent.app`. The development connection is already configured locally; credentials are excluded from source and distribution archives.

For a fresh workstation, an administrator places the clinic's configuration in `~/Library/Application Support/RadAgent/.env` using `.env.example` as the format. A source checkout also reads the repository's local `.env`. Set the file to owner-only permissions. Radiologists can then use the app without entering a key in Settings. An optional saved Keychain override takes precedence.

The app requires macOS 14+ and a separately installed Horos. Native integration was exercised on Apple silicon with Horos 4.0.1. A build uses the current machine's architecture.

### Horos setup

In **Settings → Horos → Manage**, install the bundled plugin once, then restart Horos. The plugin is installed at:

```text
~/Library/Application Support/Horos/Plugins/RadAgentEngine.horosplugin
```

Subsequent Radiology Agent launches start Horos in the background and reconnect automatically. DICOM stays in Horos's existing database. There is no Screen Recording or Accessibility requirement.

### Optional clinic API

For a local research installation with Python 3.12+:

```sh
bash scripts/start-backend.sh
```

The service listens on `127.0.0.1:8043`. It creates a private SQLite database and random API token under `~/Library/Application Support/RadAgent/backend/`. Radiology Agent discovers this local token automatically. The API is optional for local Horos browsing.

For a shared clinic deployment, see [deployment](docs/DEPLOYMENT.md) and [API integration](docs/API.md). Docker Compose is provided; it binds the published port to loopback. Use a clinic-managed HTTPS reverse proxy for remote workstations.

## Workflow

1. Open **Worklist**. Choose a study that has arrived in Horos.
2. Inspect the images and choose a template, or let the agent select one.
3. Ask for a **Draft for evaluation**. The agent reads native image frames and writes the document with key-image references.
4. Review linked phrases and images, edit the document, and use **History** when needed.
5. Copy/export a marked draft or explicitly **Save draft to clinic** from the report menu.

**New Horos studies are added and drafted automatically.** The first successful scan records the existing library as a baseline, preserving its reports. After that, a newly seen Study Instance UID appears in the worklist immediately. The app polls every 15 seconds, waits for 60 seconds without a change in image count, then requires two matching full frame inventories at least 15 seconds apart. It selects a report template, reviews native Horos images through Astra, and adds a **Draft for evaluation** with key-image links. Arrival stability is a heuristic, not proof of transfer or exam completeness.

The worker has its own study context: it never selects another study, moves your viewer, or replaces report edits made during a run. The worklist shows receiving, queued, drafting, saving, and attention states. Partial frame review is marked **Needs attention**. Right-click a failed row to retry, or an existing unreported study to queue it explicitly. **Draft new studies automatically** pauses new jobs; a running job finishes.

Keep Radiology Agent running to watch Horos. Closing its window leaves monitoring active; Quit stops it. Reopening Radiology Agent resumes the private arrival journal and detects studies received while it was closed. Completed candidates are recovered without another model run. Failed model runs back off and stop after three attempts. Additional images after completion are flagged without silently rewriting a report.

The clinic API is optional. When configured, it must be reachable before a new model job starts; an atomic, renewable 30-minute lease coordinates workers, and optimistic draft versions protect existing clinic reports. New Horos arrivals are registered in the API automatically. Explicit API jobs with `radagent-draft` and `received_complete: true` still work. Model processing uses the provisioned OpenAI connection; no signing or final report submission occurs. See [Incoming studies](docs/INCOMING_STUDIES.md) for recovery and operational limits.

The synthetic demo is separate from real studies and never represents a clinical image interpretation.

## Architecture

```text
SwiftUI workspace + AppKit document editor
    ├── AgentClient → OpenAI Responses API (store: false)
    ├── ClinicClient → FastAPI → SQLite worklist / versions / templates / audit
    └── authenticated loopback → plugin inside Horos
                                  ├── DicomDatabase: study / series / frame inventory
                                  ├── DCMPix: native pixels and windowing
                                  ├── BrowserController: native viewer
                                  └── QueryController: configured PACS retrieval
```

The integrated image pane receives lossless PNG renderings from native DICOM pixels. The model receives renders scaled to at most 2048 pixels per side. Full Horos tools remain in a separate native window; this release does not embed Horos's window hierarchy into SwiftUI or reimplement MPR/3D.

The reporting schema is original and intentionally small. Its design references [Orthanc's changes log and labels](https://orthanc.uclouvain.be/book/users/rest.html), [LibreHealth's order-to-report workflow](https://librehealth.io/projects/lh-radiology/), and [IHE multimedia reporting](https://profiles.ihe.net/RAD/IMR/volume-1.html). These are architectural references, not claims of IHE/MRRT conformance.

## Build and test

```sh
bash scripts/build.sh
bash scripts/test.sh
.venv/bin/python -m pytest backend/tests -q
python3 scripts/check-release.py
```

The native app has no third-party Swift package dependencies. AppKit viewport tests cover zoom geometry, frame presentation, focus, and cursor selection. The backend's tested dependency versions are locked in `backend/requirements.txt`. CI builds the app and tests both components. `scripts/verify-engine.py --study 'TEST PATIENT'` checks a specified local study without printing patient metadata. `scripts/package.sh` creates credential-free app and source archives.

## Scope and operational limits

- Local workspaces, templates, API tokens, and the backend database are private files. File permissions are not independent encryption.
- Agent requests send the conversation, draft context, and requested image renderings to OpenAI. Burned-in image text can contain patient information. `store: false` is not a zero-retention or compliance claim.
- The clinic backend currently uses a service token per deployment. It has no SSO, individual clinician authentication, tenant separation, or immutable external audit sink. `reviewed` is a worklist status, not a signed clinical report.
- Remote PACS retrieval, Orthanc routing, and Docker deployment have implementation/tests but have not been exercised against a clinic's remote infrastructure. The native viewer, local API intake, and live Astra drafting were tested on the local evaluation study.
- Clinical accuracy, broad modality coverage, handling of very large studies, institutional security review, signing/notarization, and production operations remain release qualification work. Images referenced by a model are not themselves proof that its interpretation is correct.

See the [production review and remaining release gates](docs/PRODUCTION_REVIEW.md), [viewer controls](docs/VIEWER.md), [security and data handling](SECURITY.md), [contributing](CONTRIBUTING.md), and [third-party notices](THIRD_PARTY_NOTICES.md).
