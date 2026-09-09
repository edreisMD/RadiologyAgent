# Research deployment

## Desktop workstation

Build with Xcode using `scripts/build.sh`, or distribute the generated app archive together with the matching source archive. Install Horos separately. The plugin dynamically uses the installed host and must be reinstalled/restarted when its version changes.

An administrator provisions `~/Library/Application Support/RadAgent/.env` with the clinic-approved OpenAI connection. The local development key is not included in any archive. Radiologists may override the default in Settings; overrides use macOS Keychain.

The current build uses local ad-hoc code signing. A public download release still needs the publisher's Apple Developer signing identity and notarization process. Do not describe the local build as notarized.

## Local reporting service

Install Python 3.12+ and run `scripts/start-backend.sh`. The service stores data under `~/Library/Application Support/RadAgent/backend/`; its random token is automatically discovered by Radiology Agent on the same Mac. The process must remain running for API intake. Local Horos worklist browsing remains available without it.

## Shared reporting service

Use the Dockerfile/Compose example with a persistent data volume and a strong `RADAGENT_API_TOKEN` supplied by the deployment environment. The published port is loopback-only. Put a clinic-managed HTTPS reverse proxy in front of it; firewall access to approved clients. Configure each workstation's `RADAGENT_BACKEND_URL` and `RADAGENT_BACKEND_TOKEN`. The backend token is a service credential and should be provisioned by the administrator.

Use a process supervisor for the API and optional Orthanc bridge. Back up the SQLite database with SQLite's online backup mechanism, or stop the service before copying the database and WAL together. Test restoration before using the service for retained research records. An example backup utility is supplied in `scripts/backup-backend.py`.

A single deployment currently serves one research team. The service token is not a substitute for individual clinician identity, SSO, tenant isolation, or policy-based access control. Those are additional requirements for a broader institutional deployment.

## Acceptance checks before a new site

Verify patient/study UID matching, all expected series and frames, transfer syntaxes, viewer orientation/windowing, template selection, draft recovery, key-image resolution, concurrent editing conflicts, and backup restore. Exercise remote DICOM query/retrieve and the Orthanc bridge against that site's non-production systems. Confirm the site's policies for model processing of image and report data.

No automated test here establishes diagnostic performance or regulatory readiness.

## Automatic incoming studies

Radiology Agent 0.5 watches the full Horos database while the app process is running, including with its window closed. Quit stops monitoring; relaunch catches up against the saved baseline. This release does not install a login item or a system daemon. Provision the app at login using the site’s normal workstation management if unattended startup is required. A configured clinic API must also be supervised and reachable. Upgrade desktop and backend together for lease renewal support. The private `incoming-studies.json` journal belongs in the workstation backup alongside `workspace.json`; do not delete it as routine cache cleanup. See [Incoming studies](INCOMING_STUDIES.md).
