# Monorepo instructions

Not for medical use, research only.

- `RadiologyConnector/` owns the connector, native Horos bridge, MCP tools, shared viewer, listener and report export.
- `RadiologyAgent/` owns the Mac application. Read each component's instructions before editing it.
- Preserve changes from other agents. Stage explicit paths and fetch before pushing; never force-push over concurrent work.
- Keep the exact research-only notice visible in interfaces and generated reports. Reports remain unsigned **Draft for evaluation** and are written in English.
- Never commit credentials, `.env` files, DICOM instances, patient metadata, screenshots of patient studies, worklist databases, generated clinical reports or private configuration.
- Runtime files stay outside the checkout. Demo display aliases are not DICOM de-identification.

## Installation requests

1. Read `docs/INSTALLATION.md` and the selected component's `AGENTS.md`.
2. Infer the requested component from the user's instructions. Use the root `scripts/install.py --component connector|app|both`; do not install an unrequested component. The app needs the connector runtime even when Codex registration is skipped.
3. Run `--check`, resolve missing prerequisites, then run `--dry-run`. Use an existing authorized report destination, or omit that option. Never invent a cloud destination or provision a new API key for the Codex workflow.
4. Run installation within the user's authorized scope. The installer preserves previous app and bridge bundles and does not restart Horos. Coordinate a restart if viewer work is active; do not interrupt another agent's study review.
5. Start a fresh Codex task after MCP registration. Verify native engine status, the selected study, actual rendered pixels, report editing, and one key-image link using the validation sequence in the guide.
6. Enable `--listener` only when requested. It does not create an automation. Configure one dispatcher only when the user asks for automatic drafting; preserve existing automation/reservation state and never duplicate a study task.
7. Report the installed component, actual path, validation performed, and any pending restart. Do not describe an untested installation as working.
