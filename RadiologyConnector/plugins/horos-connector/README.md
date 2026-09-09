# Radiology Agent Horos Connector

**Not for medical use, research only.**

For the one-command monorepo setup and agent instructions, start at [RadiologyConnector](../../README.md).

Use Codex as the radiology agent, with original DICOM delivered from Horos to a shared viewer and report editor. The same charcoal interface runs in Codex’s right browser panel and the Radiology Agent Mac app. Cornerstone3D supplies the imaging engine; OHIF’s application UI is not used.

## What is implemented

- Horos study inventory, exact study/series/image selection and original DICOM transfer. Horos owns PACS connectivity and the local DICOM database.
- A browser stack viewport with window/level, pan, zoom, invert, rotation and series navigation. Clicking a thumbnail stays inline. **Open in Horos** or a double-click on the displayed image opens a native viewer.
- Visible agent actions through MCP and browser WebMCP tools. The agent receives a capture from the displayed viewport. Radiologists can pause following, inspect independently, and resume when ready.
- A continuous editable report with patient/exam headers and radiology sections. Exact phrase links preview and pin key images. Revision checks and local history preserve edits.
- Every new study is detected by a local listener, allowed to settle, and exported as every available frame. CT/MR stacks also get segmented MP4 and contact sheets. Video paths alone are not evidence that a model reviewed a cine.
- A durable dispatcher reserves one Codex task per incoming study revision. Codex’s supported task-creation tool starts Astra; this connector never launches a hidden model client. At most two study tasks are active at once.
- Unsigned **Draft for evaluation** Word files, after page-layout review, saved to the configured Google Drive desktop sync folder under `Patient name - Patient ID`. Existing files and historical studies are not overwritten or automatically backfilled.

## Installation

Requirements: macOS 14+, separately installed Horos, Python 3.12+, Codex with local plugins, and FFmpeg on PATH for stack cine exports. Node.js 20.19+ is needed only to rebuild the frontend from source. No OpenAI API key is needed for the Codex workflow.

From source, build the shared viewer:

```sh
cd horos_connector/web
npm ci
npm run build
cd ../..
bash scripts/build-engine.sh
```

Copy `dist/RadAgentEngine.horosplugin` to `~/Library/Application Support/Horos/Plugins/` and reopen Horos. The native engine filename and installed storage paths retain their earlier identifiers for upgrade compatibility; the product name is **Radiology Agent**.

Install the runtime and listener into the current user’s account:

```sh
python3 scripts/install.py --report-directory '/absolute/path/to/Google Drive/Radiology Agent' --listener
```

Existing installations keep their configured report directory, including a folder previously named `RadAgent`. The listener label is `org.radiologyagent.horos-listener`. It starts at login and requires Horos to be available. Install this directory as a Codex plugin using its `plugin.json` and `mcp.json`; the local marketplace installer also supports `.codex-plugin/plugin.json`.

## In Codex

Ask Codex to open the worklist with `open_workspace` and show its URL in the right browser panel. Resolve an exact study UID, inventory it, and claim its worklist job when drafting. Use browser tools or `inspect_view` for visible navigation, and `current_view` to receive the corresponding image. Use `update_workspace_report` for the report pane, then `prepare_report` and `publish_report` for the reviewed Word document.

Browser WebMCP tools are named `radiology_agent_worklist`, `radiology_agent_open_study`, `radiology_agent_workspace`, `radiology_agent_inspect`, and `radiology_agent_save_report`. The page exposes them only where WebMCP is supported. Standard browser controls and MCP tools remain available independently.

Set one recurring Codex dispatcher to call `study_runs`, reconcile unresolved reservations, then call `reserve_study_run`. For a successful reservation it calls Codex `create_thread` with the returned prompt/title/model and a projectless target, then `attach_study_run`. Never retry uncertain task creation blindly. The local `scripts/dispatch.py` JSON-stdin interface supports older threads that have not refreshed their tool catalog.

## Boundaries and recovery

The local viewer uses an owner-only descriptor, bearer authorization, exact loopback Host/Origin checks and no external assets. DICOM files are returned only after exact study/image selection and identity validation. Horos’s internal series sorting key is distinct from its DICOM Series Instance UID. No recursive search of patient files is used.

Private configuration, queue state, original DICOM, image exports, browser captures and report history stay in `~/Library/Application Support/RadAgent/connector/`. Keep that directory in the workstation’s protected backup. The report directory is the only sync destination. Local file verification does not verify Google Drive cloud sync.

An older native bridge uses an explicitly labelled Horos preview until Horos is reopened with the updated plugin. Current original-DICOM rendering was exercised with a two-series CR study and a four-series, 1,240-frame CT inventory, including stack navigation and native viewer handoff. Synthetic tests cover multiframe mapping and identity rejection. CT/MR stacks are supported by the engine; this is not validation across every modality, compression scheme or acquisition. MPR, volumetric segmentation, clinical signing and regulatory clearance are not part of this research preview.

The pinned codec worker requires Emscripten function generation; its worker response has a dedicated CSP. The document and all other responses keep JavaScript eval disabled. See [third-party notices](THIRD_PARTY_NOTICES.md) for bundled licenses.

## Development checks

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q
python3 scripts/package.py
```

The archive excludes credentials, patient data, local queues and dependencies installed into private runtimes. Source uses the [official MCP SDK](https://github.com/modelcontextprotocol/python-sdk), [Cornerstone3D](https://www.cornerstonejs.org/docs/tutorials/basic-stack/) and [Codex plugin support](https://developers.openai.com/plugins/build/plugins). Horos remains separately installed and licensed. The bridge is original MIT code using narrow ABI declarations, not a fork of Horos.
