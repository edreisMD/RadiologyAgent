# Contributing

Use synthetic fixtures in tests and issues. Keep DICOM files, real patient names, credentials, and runtime databases out of the repository. Preserve compatibility with existing workspace files when extending Codable models; new persistent fields should be optional or explicitly migrated.

Run the Swift tests, backend tests, native build, and release-content check before proposing a change. Test Horos adapter changes against the installed host SDK and verify that study/frame ownership is preserved. Report exactly which Horos/macOS versions and modalities were exercised.

The app's normal interaction is thumbnails inside Radiology Agent, with an explicit Open in Horos action or double-click on the displayed image. Preserve the document editor and its evidence links. Do not add report-signing or silent external submission behavior to the research workflow.

The GitHub Actions workflow provides repeatable build/test checks. Apple signing, notarization, and site-specific infrastructure validation are separate release tasks.
