# Radiology Agent Mac app

Not for medical use, research only.

- Preserve the shared DICOM viewer, listener and MCP implementation in `../RadiologyConnector/`.
- `scripts/build.sh` bundles that connector into the Mac app; do not create a divergent viewer implementation here.
- The old native SwiftUI workspace is retained for compatibility. Codex owns the default agent workflow.
- Use the supplied logo in Resources. Never include local configuration, credentials, patient images, workspace state, or generated reports in source or releases.
- Run `scripts/test.sh` for Swift changes, build the app, and check the actual WKWebView for visual changes.
