# Radiology Connector

**Not for medical use, research only.**

Use Codex to inspect studies in Horos, manipulate an original-DICOM viewer in its right sidebar, and write English, unsigned **Draft for evaluation** reports beside the images. The shared viewer uses Cornerstone3D with Radiology Agent's own interface. Horos retains PACS connectivity and the study database.

The connector lives entirely in this folder; the Mac application is the sibling `RadiologyAgent/` component. The installable plugin is [`plugins/horos-connector/`](plugins/horos-connector/README.md). Its internal name and private storage paths retain earlier identifiers for upgrade compatibility.

## Install

Requirements: macOS 14+, Horos in `/Applications/Horos.app`, Python 3.12+, Node.js 20.19+ (or 22.12+), npm, FFmpeg, Xcode Command Line Tools, and Codex with its CLI installed. Install Horos separately from its official distribution. The Codex workflow does not require an OpenAI API key.

```sh
git clone https://github.com/edreisMD/RadiologyAgent.git
cd RadiologyAgent/RadiologyConnector
python3.12 scripts/setup.py --check
python3.12 scripts/setup.py --report-directory '/absolute/path/to/your/report-folder'
```

Create the report folder first. A Google Drive desktop sync folder works: the connector writes a Word document locally and Google Drive performs the sync. Omit `--report-directory` to keep an existing destination or configure one later. Use `--listener` to also enable the incoming-study listener at login.

The setup command builds the web viewer and native Horos plugin, preserves any previous bridge in a dated backup, installs the private Python runtime, and registers `radiology-connector` with `codex mcp add`. It does not stop Horos or create a recurring Codex task. Use `--dry-run` to inspect the operations or `--skip-codex` to install the bridge/runtime only.

Reopen Horos when existing viewer work can safely be closed. Then start a **new Codex task** so its tool catalog includes the connector. For a coding agent, use the complete procedure in [AGENTS.md](AGENTS.md).

Ask Codex:

> Read RadiologyConnector/plugins/horos-connector/skills/horos-research/SKILL.md. Open the Horos worklist in the right sidebar. Find the study I select, inspect all available series, and draft an English report in the report pane with supporting key-image links. Keep it unsigned and include “Not for medical use, research only.”

## Incoming studies

```sh
python3.12 scripts/setup.py --listener --report-directory '/absolute/path/to/your/report-folder'
```

The listener waits for stable inventory, exports each available frame, and leaves existing studies as a baseline. It does **not** invoke a model. After explicitly requesting automatic reporting in Codex, use the [dispatcher instructions](docs/AUTOMATION.md) to create one scheduled dispatcher. Each newly ready study gets one separate Astra task. Durable reservations prevent duplicate task creation, with at most two active studies.

## Data and research limits

Private runtime data stays in `~/Library/Application Support/RadAgent/connector/`, outside this repository. Original DICOM is resolved by exact study/series/instance identity. Selected stacks prefetch in the viewer, and interactive scrolling renders locally before synchronizing the final position.

Demo aliases mask displayed names only: original DICOM tags and possible burned-in text remain unchanged. Exported image paths or videos do not prove the model reviewed them. Models must inspect image content and disclose incomplete review. The connector does not sign reports, certify examination completeness, or provide clinical validation.

## Develop and test

```sh
cd plugins/horos-connector
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q
cd horos_connector/web
npm ci
npm run build
```

From `RadiologyConnector/`, run `python3 scripts/check_release.py` before publishing source. See the [tool guide](plugins/horos-connector/README.md), [MIT license](plugins/horos-connector/LICENSE), and [third-party notices](plugins/horos-connector/THIRD_PARTY_NOTICES.md).
