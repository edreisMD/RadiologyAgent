#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-release.py
python3 ../RadiologyConnector/scripts/check_release.py
ditto -c -k --sequesterRsrc --keepParent "dist/Radiology Agent.app" "dist/Radiology Agent-macOS.zip"
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
root=Path.cwd()
include=['Package.swift','README.md','LICENSE','THIRD_PARTY_NOTICES.md','SECURITY.md','CONTRIBUTING.md','.env.example','.gitignore','.dockerignore','compose.yaml','Sources','EnginePlugin','Resources','Tests','backend','scripts','docs','.github']
with ZipFile(root/'dist/Radiology Agent-source.zip','w',ZIP_DEFLATED) as archive:
 for item in include:
  path=root/item
  for file in (path.rglob('*') if path.is_dir() else [path]):
   if file.is_file() and not any(part in {'__pycache__','.pytest_cache','node_modules','.venv','dist'} for part in file.relative_to(root).parts):
    archive.write(file,'RadiologyAgent/'+str(file.relative_to(root)))
 source=root.parent/'RadiologyConnector'
 if source.is_dir():
  for file in source.rglob('*'):
   if file.is_file() and not any(part in {'__pycache__','.pytest_cache','node_modules','.venv','dist','build'} for part in file.relative_to(source).parts):
    archive.write(file,'RadiologyConnector/'+str(file.relative_to(source)))
 # Include the monorepo entry points needed by a fresh source checkout.
 for item in ['README.md','AGENTS.md','LICENSE','.gitignore','scripts','tests','docs','.github']:
  path=root.parent/item
  for file in (path.rglob('*') if path.is_dir() else [path]):
   if file.is_file() and '__pycache__' not in file.parts:
    archive.write(file,str(file.relative_to(root.parent)))
print('Created app and source archives without local configuration or patient data.')
PY
