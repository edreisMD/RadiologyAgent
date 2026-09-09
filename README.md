# Radiology Agent

**Not for medical use, research only.**

A research monorepo for a radiology workspace and its Codex integration.

| Component | Purpose |
| --- | --- |
| [RadiologyConnector](RadiologyConnector/README.md) | Horos DICOM bridge, Codex tools, shared Cornerstone viewer, incoming-study listener, and unsigned report drafts. |
| RadiologyAgent | Mac application, maintained as a separate component. |

Start with the [connector installation guide](RadiologyConnector/README.md#install) or the [instructions for coding agents](RadiologyConnector/AGENTS.md). Horos is installed separately. Credentials, studies, patient data, and local reports must never be committed to this repository.
