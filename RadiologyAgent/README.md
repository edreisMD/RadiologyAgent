# Radiology Agent for macOS

**Not for medical use, research only.**

The Mac companion app uses the same Horos-backed Cornerstone3D viewer and report document as Codex. Radiologists can navigate images, inspect linked findings, and edit an unsigned **Draft for evaluation** while Codex works with the shared study.

## Install

From the monorepo root:

```sh
python3.12 scripts/install.py --component both --check
python3.12 scripts/install.py --component both
```

Use `--component app` for the companion viewer without registering Codex tools. This still installs the required Horos bridge and Python runtime. The app is installed into `~/Applications/Radiology Agent.app`, with any previous bundle preserved as a dated backup. The installer does not restart Horos or launch the app.

See [complete installation instructions](../docs/INSTALLATION.md) for prerequisites, Word report destinations, incoming-study monitoring, downloadable builds, validation, and upgrades. The default Codex workflow requires no OpenAI API key. Horos must be installed separately. The research app is ad-hoc signed, not notarized.

## Use

- Open the worklist and choose a study from Horos.
- Navigate the original-DICOM image stack with scrolling, window/level, pan, zoom, rotation, and inversion. Selected series prefetch in the background.
- Use **Images**, **Report**, or **Split**. Both Codex and the app share the study's report state.
- Hover a linked report phrase to preview its key image; click to pin it.
- Manual navigation pauses following Codex. Resume following when you want to watch agent actions.
- Thumbnails stay inline. **Open in Horos** or a double-click on the image opens the exact native series/frame.
- Use **Edit draft** to revise the continuous report. Revision checks preserve concurrent edits. Reports remain unsigned and in English.

The app is a companion workspace, not an embedded copy of Codex's authenticated chat runtime. Automatic drafting uses the connector listener plus a separately configured Codex dispatcher. The [earlier native API-backed interface](docs/LEGACY_NATIVE_UI.md) remains available through the Study menu; its automatic worker is not started with the shared workspace.

## Build and test

From the monorepo root:

```sh
npm ci --prefix RadiologyConnector/plugins/horos-connector/horos_connector/web
bash RadiologyAgent/scripts/test.sh
bash RadiologyAgent/scripts/build.sh
python3.12 RadiologyAgent/scripts/check-release.py
bash RadiologyAgent/scripts/package.sh
```

The build bundles the shared connector from `../RadiologyConnector/plugins/horos-connector`. Set `RADIOLOGY_CONNECTOR_SOURCE` only when intentionally building against a different plugin checkout. Generated artifacts are in `RadiologyAgent/dist/` and are excluded from Git.

See [architecture](docs/CODEX_WORKSPACE.md), [demo walkthrough](docs/HACKATHON_DEMO.md), [security](SECURITY.md), [third-party notices](THIRD_PARTY_NOTICES.md), and [MIT license](LICENSE). The optional clinic API has separate [API](docs/API.md) and [deployment](docs/DEPLOYMENT.md) guides.
