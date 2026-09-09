# Shared Codex workspace

Radiology Agent 0.6 defaults to the same browser workspace used by its Codex connector. Horos remains the local DICOM/PACS backend, Cornerstone3D renders original images, and Codex is the agent. The app is a companion viewer/report editor; it does not embed or imitate Codex’s authenticated chat runtime.

Open **Radiology Agent.app** to use the shared worklist. In Codex, `open_workspace` supplies a URL for its right browser panel. State and evaluation drafts are shared by exact study revision, and radiologist interactions pause following automatically. The **Open in Horos** action or a double-click on the displayed image launches a native viewer.

Use **Study → Shared Codex workspace** to switch to the earlier native interface. Automatic model work in that legacy interface no longer starts alongside the Codex workflow, preventing duplicate model runs. Its manually invoked reporting and clinic API features remain available.

The local listener monitors arrivals every ten seconds. A minutely Codex dispatcher reserves ready studies and creates separate Astra tasks, with at most two active studies. Arrival quiet periods are an operational heuristic, not proof that an examination is clinically complete. Initial historical studies stay baseline-only.

The source and private directory names retain `RadAgent` for upgrade compatibility; user-facing names and the app bundle use **Radiology Agent**. Keep the existing private data and report destinations during upgrades. See the [connector guide](../../RadiologyConnector/README.md) for installation, tools, recovery and limits.
