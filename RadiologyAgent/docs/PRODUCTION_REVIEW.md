# Production review — 0.5.0

Review performed against the local macOS/Horos installation on 2026-09-08. This is a source, interaction, and integration review. It is not clinical validation or a certification of production readiness.

## Findings corrected

| Finding | Correction and evidence |
| --- | --- |
| The report editor could leave the text cursor active outside its bounds; clickable surfaces lacked feedback. | Scoped AppKit cursor tracking, explicit exit cleanup, link cursor rectangles, consistent button/menu hover and pressed feedback. Native cursor-selection tests and desktop interaction checks. |
| The viewport provided only generic dragging, with no native window/level or stack gestures. | Dedicated AppKit image canvas, pointer-anchored zoom, pan, per-series navigation, local keyboard focus, coalesced native window renders. Geometry/focus/presentation tests; actual window/level and zoom exercised on local DICOM. |
| Agent tools moved the radiologist's selected image and shared mutable window settings. | Agent render state is separate. Tool evidence records the frame and native window actually reviewed, independent of UI selection. |
| Concurrent study-open requests could apply an older response; native inventory identity was incompletely checked. | Study-open generation guards and validation of requested Study UID, frame count, unique IDs, and global indices. Invalid inventory tests. |
| A tagged manual conversation could automatically save to the clinic. | Only a specifically claimed automatic job can trigger automatic backend save. Failed saves keep the study open and preserve the local draft. |
| Expired workers could still submit after another worker acquired the study. | Unexpired claim token required at automatic draft save, plus optimistic draft revisions. A regression test expires the first worker, reclaims the study, and rejects the first worker's save. |
| Duplicate evidence IDs could crash the native editor's dictionary initializer. | Backend rejects duplicate IDs; native editor tolerates malformed older data without crashing. |
| Explicit blank patient IDs could erase an existing identity. | Arrival update rejects identity changes, including clearing an established patient ID. |
| Incoming worklists loaded every database row and acquired writer locks for reads. | SQL pagination, deterministic ordering, indexed fields, separate read transactions in WAL mode. |
| Shared URL sessions could retain content or follow redirects. | Ephemeral sessions, no disk cache/cookies, redirects rejected for OpenAI, clinic, and engine clients. Address validation and redirect-policy tests. |
| Image/thumbnail caches and queued engine requests were insufficiently bounded. | Cost-limited render caches, small materialized thumbnails, capped pending engine connections, send and receive timeouts. |
| Remote template refresh could replace a locally edited template. | Local modifications are retained until explicitly shared; revision conflicts remain visible. |
| Native viewer handoff opened only a series, potentially at another slice. | Validated frame selection and current window values are passed through the installed Horos SDK. |

Cursor handling follows Apple's [tracking-area and cursor-update guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html). Native viewer operations use declarations verified in the locally installed Horos 4.0.1 SDK. No third-party Horos implementation is copied into Radiology Agent.

## Release gates still open

1. **Diagnostic viewer qualification.** The inline canvas displays PNG renders from DCMPix, not an embedded Horos OpenGL view. Validate orientation, pixel aspect ratio, calibration, bit depth, grayscale presentation, and responsiveness for every intended modality/transfer syntax and large/multiframe studies. Inline ROI measurement, MPR, 3D, and comparison synchronization are not implemented.
2. **Clinical evaluation.** Establish report accuracy, missed-findings rates, coverage reporting, key-image correctness, uncertainty handling, and radiologist acceptance on representative held-out cases. Automated software tests do not establish these outcomes. Drafts require clinician review.
3. **Institutional identity and access.** The clinic backend has one service token per deployment. It still needs individual clinician authentication, roles, scoped access, attribution, immutable external audit storage, and policy-controlled retention for broader deployment.
4. **Data governance.** Qualify model processing and storage arrangements for each institution. Patient text or burned-in identifiers may be sent to the configured model service. Local file permissions are not independent encryption; configure device and backup protection through the institution.
5. **Operational qualification.** Exercise Orthanc and remote PACS in the site's staging environment; validate partial arrivals, duplicate sources, outages, retries, dead-letter handling, large worklists, lease expiry, monitoring, backup restoration, and deployment rollback. Automatic intake runs while the app is running, independently of the visible study. It uses a durable arrival journal, bounded retries and renewable clinic leases. The first scan baselines existing studies. Site acceptance must still exercise a real modality/PACS arrival, app termination during save, large multiframe studies, and additional images after reporting.
6. **Distribution.** Use a publisher-owned Developer ID, hardened runtime/notarization, reproducible release artifacts, dependency review, and a supported update process. The local app remains ad-hoc signed. Horos is installed separately with its own license.

## Scope of verification

The automated suite covers native interaction logic, request boundaries, study identity, report/evidence persistence, template matching, Word document round-trip, backend authorization, idempotency, lease ownership, and conflicting saves. Desktop checks use the existing local evaluation study, without finalizing its report. Remote clinic infrastructure and broad modality performance remain unverified.

Final local verification: **33 Swift/AppKit tests and 15 backend tests passed**. Native engine checks passed for authentication, exact-study inventory, rendering, window reset, and cross-study rejection. The live Astra isolation test reviewed and re-windowed frame 0 while the radiologist's viewport remained on frame 1 with its prior window values; the report was unchanged. Explicit native handoff displayed that same selected frame with matching width/level. A startup regression involving an offscreen cursor rectangle was reproduced, fixed, and covered by a regression test. Hover glyph detection and preview cleanup are covered by an AppKit event test; the desktop automation does not expose a pure pointer-hover action.
