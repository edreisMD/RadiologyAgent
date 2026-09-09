# Third-party components

Radiology Agent's original source is MIT licensed. The app requires a separately installed Horos application; no Horos executable, decoder library, or implementation source is redistributed in the app bundle.

The engine adapter uses a small set of ABI declarations based on the public Horos SDK. Horos is a separate project under LGPL-3.0; its source and dependency licensing information are available at https://github.com/horosproject/horos. The adapter's complete source and reproducible build are included here. Horos and its trademarks belong to their respective owners.

The backend uses FastAPI, Starlette, Pydantic, Uvicorn, HTTPX, and their dependencies. Their installed distributions retain their license files. Exact tested versions are in `backend/requirements.txt`.

The original templates contain structure and placeholders. No RSNA, Radiopaedia, LibreHealth, or other third-party case or report text is bundled.

The shared browser workspace bundles Cornerstone3D and its dependencies. See the [complete dependency notices](connector/horos-connector/THIRD_PARTY_NOTICES.md).
