# Monorepo instructions

Not for medical use, research only.

- `RadiologyConnector/` owns the connector, native Horos bridge, MCP tools, shared viewer, listener and report export.
- `RadiologyAgent/` owns the Mac application. Read each component's instructions before editing it.
- Preserve changes from other agents. Stage explicit paths and fetch before pushing; never force-push over concurrent work.
- Keep the exact research-only notice visible in interfaces and generated reports. Reports remain unsigned **Draft for evaluation** and are written in English.
- Never commit credentials, `.env` files, DICOM instances, patient metadata, screenshots of patient studies, worklist databases, generated clinical reports or private configuration.
- Runtime files stay outside the checkout. Demo display aliases are not DICOM de-identification.
