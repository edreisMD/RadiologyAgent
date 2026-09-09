# Installing and working on Radiology Connector

Not for medical use, research only.

This is the connector component. Do not move or overwrite the sibling Mac app. The self-contained plugin is `plugins/horos-connector/`; maintain its normalized plugin name for compatibility.

## Agent installation procedure

1. Read `README.md` and `plugins/horos-connector/skills/horos-research/SKILL.md`. Confirm macOS 14+, Horos, Python 3.12+, Node/npm, FFmpeg, and Xcode Command Line Tools. Run `python3.12 scripts/setup.py --check` to report missing prerequisites without changing configuration.
2. Resolve a report destination from the user's instructions or existing private configuration. Never invent a cloud destination or ask for an OpenAI API key. If no destination is specified, install without that option and keep drafts local until a destination is provided.
3. Run `python3.12 scripts/setup.py --dry-run` to see the steps. Run setup with the chosen `--report-directory` when installation is authorized. Add `--listener` only when incoming-study monitoring is requested. The installer builds local code, installs the private runtime and Horos bridge, preserves an existing bridge, and registers the MCP server with Codex's CLI. Keep this checkout at a stable path after installation.
4. The installer never closes Horos. If it is open, arrange a restart within the user's authorized scope; do not interrupt another radiology review. Start a new Codex task after MCP registration so the tools become available.
5. Validate `horos_status`, then `find_studies` and `study_inventory` for an explicitly chosen study. Use `open_workspace`, show its returned URL in the right browser panel, and verify an image actually renders. Do not search the entire patient database directory or infer successful image access from a filename.
6. Use `inspect_view`/browser WebMCP for visible review and inspect the returned image. Respect the radiologist's follow setting. Read every series and all frames for a comprehensive draft. Write an English, unsigned **Draft for evaluation** through `update_workspace_report` with exact phrase-to-image links. Include the exact research-only notice.
7. For Word export, use `prepare_report`, render and inspect every page using the Documents skill, then `publish_report(layout_reviewed=true)` to the configured folder. A verified local save does not confirm Google Drive cloud sync.
8. Create a scheduled dispatcher only if requested, following `docs/AUTOMATION.md`. Never dispatch historical or already completed studies automatically, and reconcile uncertain task creation before retrying.

## Development

- Test Python changes from the plugin directory with its runtime: `python -m pytest -q`.
- Build the frontend with `npm ci && npm run build` from `horos_connector/web`; do not replace assets or restart the service during an active review without coordinating with that run.
- The web source is shared with the Mac app. Coordinate presentation changes with the app agent; do not overwrite concurrent edits.
- `Not for medical use, research only.` must appear in the UI and generated reports. Do not convert drafts into signed/final clinical reports.
- Never commit secrets, patient data, runtime databases, screenshots of real studies, generated reports, or private configuration. Run `python3 scripts/check_release.py` before publication.
- Demo aliases are presentation-only; do not describe them as DICOM anonymization.
