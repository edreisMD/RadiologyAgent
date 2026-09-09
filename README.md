# Radiology Agent

**Not for medical use, research only.**

A shared radiology workspace for **Codex and macOS**. Codex operates a visible DICOM viewer, checks studies supplied by Horos, and writes an English **Draft for evaluation** with linked key images. Radiologists can inspect the same study and edit the same document in the Mac companion app.

| Component | Purpose |
| --- | --- |
| [RadiologyConnector](RadiologyConnector/README.md) | Horos DICOM bridge, Codex tools, shared Cornerstone viewer, incoming-study listener, and unsigned report drafts. |
| [RadiologyAgent](RadiologyAgent/README.md) | Branded SwiftUI/WKWebView Mac app using the same viewer, study state, and report document. |

## Install what you need

Requires macOS 14+, separately installed Horos, Python 3.12+, Node/npm, FFmpeg, and Xcode Command Line Tools. Codex is required for the connector's agent workflow. See the [complete installation guide](docs/INSTALLATION.md) for prerequisites, upgrades, and troubleshooting.

```sh
git clone https://github.com/edreisMD/RadiologyAgent.git
cd RadiologyAgent
python3.12 scripts/install.py --component both --check
python3.12 scripts/install.py --component both
```

Choose `--component connector`, `--component app`, or `--component both`. App-only installs the Horos bridge/runtime but skips Codex registration. `--dry-run` shows planned operations without installing. A source build installs the app into `~/Applications/`; existing app and bridge bundles are backed up.

To configure Word exports and incoming-study monitoring, add an existing destination and the listener flag:

```sh
python3.12 scripts/install.py --component both --listener \
  --report-directory '/absolute/path/to/your/report-folder'
```

The installer does not stop Horos, launch the app, create a schedule, or import patient studies. Reopen Horos when safe and start a new Codex task to load the connector tools. No OpenAI API key is required for the default Codex workflow.

**Installing with an agent?** Ask it to read [AGENTS.md](AGENTS.md) and [the installation guide](docs/INSTALLATION.md), then install your chosen component. [Research downloads](https://github.com/edreisMD/RadiologyAgent/releases) include the Mac app; the connector runtime must still be installed on that workstation.

## How it works

```text
PACS → Horos database → native bridge → original DICOM → Cornerstone3D viewer
                                                      ↕
                                             Codex tools and review
                                                      ↕
                                      shared report + linked key images
                                                      ↓
                                       reviewed unsigned Word document
```

- The same custom viewer runs in Codex's right browser panel and the Mac app. It uses Cornerstone3D, not OHIF's application UI.
- Selected stacks prefetch; scrolling, window/level, zoom, and pan render locally. Manual navigation pauses following the agent.
- Clicking a report phrase pins its key image. Double-clicking an image or choosing **Open in Horos** opens that exact native series/frame.
- A local listener prepares newly arriving studies. An explicitly configured Codex dispatcher starts one separate Astra task per ready study. See [automatic incoming studies](RadiologyConnector/docs/AUTOMATION.md).
- Reports remain unsigned, with revision checks to preserve radiologist edits. Word files can be saved into a Google Drive desktop sync folder.

## Demo and validation

The local research demo exercised a two-image CR study and all 1,240 frames of a four-series CT study, including visible navigation, an English draft, four key-image links, and a visually reviewed Word export. These are workflow checks, not clinical validation. The [demo walkthrough](RadiologyAgent/docs/HACKATHON_DEMO.md) describes the presentation sequence.

Run [development checks](docs/INSTALLATION.md#development-checks) before contributing. GitHub Actions tests the installer, connector, API, and Swift components and builds the Mac app. Source and release checks reject credential-shaped strings, DICOM files, and runtime databases.

Horos is separately installed and licensed. Display aliases do not de-identify DICOM tags or burned-in pixels. The app is an ad-hoc-signed research build, not notarized for general distribution. Credentials, patient studies, screenshots of real studies, reports, and runtime state are excluded from this repository. See [security](RadiologyAgent/SECURITY.md), [third-party notices](RadiologyAgent/THIRD_PARTY_NOTICES.md), and the [MIT license](LICENSE).
