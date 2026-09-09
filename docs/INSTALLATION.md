# Installation and operations

**Not for medical use, research only.**

## Choose a component

| Choice | Installs | Does not install |
| --- | --- | --- |
| `connector` | Horos bridge, private Python runtime, web viewer, Codex MCP registration | Mac app |
| `app` | Horos bridge, private runtime, web viewer, Mac app | Codex MCP registration |
| `both` | All of the above | A hidden model service or recurring schedule |

App-only is a companion viewer/report editor. Install the connector when you want Codex to operate it. The earlier API-backed native interface is optional and documented separately in [Legacy native workspace](../RadiologyAgent/docs/LEGACY_NATIVE_UI.md).

## Prerequisites

- macOS 14 or later. Native builds target the architecture of the build machine; the initial downloadable build targets Apple silicon.
- Horos, installed separately at `/Applications/Horos.app`, with a functioning local database. Use `--horos-app /path/to/Horos.app` for the prerequisite check if installed elsewhere. PACS connections remain configured in Horos.
- Python 3.12 or later, including `venv` and `pip`.
- Node.js 20.19+ or 22.12+, and npm. The installer builds the pinned frontend with `npm ci`.
- FFmpeg and ffprobe on PATH for CT/MR cine export and connector tests.
- Xcode Command Line Tools: `clang`, `codesign`, and `swift`. If missing, install them with `xcode-select --install` and complete Apple's installation dialog before continuing.
- Codex and its CLI for `connector` or `both`. The installer checks PATH and the bundled CLI in `/Applications/Codex.app` or `/Applications/ChatGPT.app`.

The installer reports missing tools rather than installing package managers, accepting license agreements, changing system security settings, or asking for credentials. Install dependencies through your workstation's normal software-management process. A network connection is needed for Python/npm dependency downloads.

## Source installation

```sh
git clone https://github.com/edreisMD/RadiologyAgent.git
cd RadiologyAgent
python3.12 scripts/install.py --component both --check
python3.12 scripts/install.py --component both --dry-run
python3.12 scripts/install.py --component both
```

Replace `both` with `connector` or `app` as needed. Keep the checkout at a stable path: the MCP registration and optional listener reference its connector code. The app bundles a copy of the shared viewer, so rebuild it when upgrading that source.

To configure Word reports, create a destination folder first and add `--report-directory '/absolute/path/to/folder'`. Omitting the option preserves an existing destination; a new installation can prepare local drafts but cannot publish until a destination is configured. Google Drive Desktop works through its local sync folder; a local save is not confirmation of cloud sync.

The app is installed to `~/Applications/Radiology Agent.app`. Change the parent directory with `--app-directory`. No administrator access is needed for that default. An existing app is renamed to a dated backup alongside the new bundle. The previous native bridge is backed up under the private connector directory before it is updated.

Reopen Horos when existing viewer work can safely be closed, then open the Mac app. After Codex registration, start a **new task** so it loads the tools. The installer does not quit or restart either application.

## Downloaded app

1. Download the Mac app archive from [Releases](https://github.com/edreisMD/RadiologyAgent/releases).
2. Verify its SHA-256 against the release's `SHA256SUMS.txt`, then extract it and place the app in `~/Applications`.
3. Clone this repository and install `--component connector` for Codex integration. For a viewer-only workstation, run `python3.12 RadiologyConnector/scripts/setup.py --skip-codex` to install the underlying bridge and runtime without building the app again.
4. Reopen Horos and open the app yourself. This research build is ad-hoc signed and not notarized; use your organization's normal policy for locally built research applications. Agents must not bypass macOS security protections.

The app archive alone does not include a Python runtime, Horos, model credentials, patient studies, or a configured report destination.

## Verify the installation

1. Check registration with `codex mcp get radiology-connector --json` when Codex integration was selected. Existing plugin installations may use the older `horos` server name; use one integration rather than running duplicates.
2. In a fresh Codex task, read `RadiologyConnector/plugins/horos-connector/skills/horos-research/SKILL.md` and call `horos_status`. Confirm the native engine is available and supports `dicom-original`.
3. Select an authorized study using `find_studies` and `study_inventory`. Call `open_workspace` and display the returned URL in the right browser panel. Verify actual images appear. Window/level and slice controls must change the image, not just metadata.
4. Open the Mac app if installed. It should show the same worklist and study/report state. Thumbnail selection stays inline; native opening is explicit through the button or double-click.
5. For a reporting test, claim the selected job, inspect all required images, save an English unsigned draft with a key-image link, and verify the phrase opens the correct image. Render and review the Word document before publishing to the configured destination.

## Automatic arrivals

Add `--listener` to installation only when incoming-study monitoring is wanted. It creates the user's `org.radiologyagent.horos-listener` LaunchAgent, which scans about every ten seconds and waits for at least thirty seconds of unchanged inventory before preparing the study. The first scan establishes a historical baseline.

The listener does not run a model. A separate, explicitly requested Codex dispatcher creates one Astra task for each ready study revision. Use [the automation guide](../RadiologyConnector/docs/AUTOMATION.md), inspect existing automations before adding one, and reconcile unresolved reservations before retrying task creation. Export time and the dispatch schedule add latency; this is not an instant callback from PACS. Test with an explicitly selected new study rather than resetting the baseline or duplicating a completed job.

## Private files

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Horos/Plugins/RadAgentEngine.horosplugin` | Native bridge loaded by Horos |
| `~/Library/Application Support/RadAgent/connector/runtime/` | Private Python environment |
| `~/Library/Application Support/RadAgent/connector/config.json` | Report destination, language and listener settings |
| `~/Library/Application Support/RadAgent/connector/` | Worklist, images, DICOM cache, drafts, viewer state and logs |
| `~/Library/LaunchAgents/org.radiologyagent.horos-listener.plist` | Optional listener configuration |
| `~/Applications/Radiology Agent.app` | Default Mac app destination |

These paths retain `RadAgent` for upgrade compatibility. Do not rename them during an upgrade. The listener logs are `listener.stdout.log` and `listener.stderr.log`; the viewer log is `workspace.stderr.log`, all in the private connector directory. Avoid pasting raw logs containing patient data into public issues.

## Troubleshooting and upgrades

| Symptom | Check |
| --- | --- |
| Missing native engine or Horos preview only | Horos must load the new plugin after a safe restart. Confirm `dicom-original` in `horos_status`. |
| Tools missing in Codex | Check MCP registration and start a new task. Existing tasks can retain an old tool catalog. |
| App says to install the connector runtime | Run the installer; copying the `.app` alone is insufficient. |
| Image not displayed | Check Horos availability, exact study inventory, and the viewer's error message. Do not recursively scan the patient database folders. |
| Agent does not move the displayed image | Manual interaction pauses follow mode. The radiologist can choose **Resume following Codex**. |
| New study does not draft | Check listener freshness, stable arrival/export status, and the separate Codex dispatcher. Historical baseline studies do not auto-run. |
| Word export fails | Verify the configured directory exists and the claim remains valid. Preserve the local draft and any edited destination file. |
| Old UI after upgrade | Coordinate with active studies before restarting the local workspace service or reopening its page. Do not discard report state. |

For an upgrade, finish active reviews, run `git pull --ff-only`, then rerun the same installer options. The report destination is retained unless explicitly replaced. The installer does not reset the worklist baseline, erase reports, or remove old backup bundles. If the named MCP configuration belongs to unrelated software, installation stops rather than overwriting it.

To stop incoming monitoring, pause the Codex dispatcher and unload the listener with `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/org.radiologyagent.horos-listener.plist`. To unregister the direct MCP installation, use `codex mcp remove radiology-connector`. Preserve private studies, configuration, reports, and backups unless their deletion is explicitly requested.

## Development checks

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r RadiologyConnector/plugins/horos-connector/requirements.txt -r RadiologyAgent/backend/requirements.txt
.venv/bin/python -m unittest discover -s tests -v
(cd RadiologyConnector/plugins/horos-connector && ../../../.venv/bin/python -m pytest -q)
(cd RadiologyAgent && ../.venv/bin/python -m pytest backend/tests -q)
npm ci --prefix RadiologyConnector/plugins/horos-connector/horos_connector/web
bash RadiologyAgent/scripts/test.sh
bash RadiologyAgent/scripts/build.sh
python3.12 RadiologyConnector/scripts/check_release.py
python3.12 RadiologyAgent/scripts/check-release.py
```

These tests use synthetic fixtures and temporary storage. They do not constitute clinical validation or verify a site's remote PACS configuration.
