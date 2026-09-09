#!/usr/bin/env python3
"""Create the shareable connector archive using an explicit allowlist."""
from pathlib import Path
import re
from zipfile import ZipFile,ZIP_DEFLATED
root=Path(__file__).resolve().parents[1]
output=root/'dist/Horos-Connector.zip';output.parent.mkdir(exist_ok=True)
include=['.codex-plugin','plugin.json','mcp.json','horos_connector','skills','scripts','native','tests','pyproject.toml','requirements.txt','README.md','LICENSE','THIRD_PARTY_NOTICES.md','dist/RadAgentEngine.horosplugin']
files=[]
for item in include:
 path=root/item
 for file in (path.rglob('*') if path.is_dir() else [path]):
  if not file.is_file() or any(part in file.parts for part in ('__pycache__','node_modules','.venv','.pytest_cache')):continue
  raw=file.read_bytes()
  if re.search(rb'sk-proj-[A-Za-z0-9_-]{30,}',raw):raise SystemExit('Credential-shaped content rejected.')
  if file.suffix.lower() in {'.dcm','.dicom','.sqlite3'} or file.name=='.env':raise SystemExit('Private data rejected.')
  files.append(file)
with ZipFile(output,'w',ZIP_DEFLATED) as archive:
 for file in files:archive.write(file,'horos-connector/'+str(file.relative_to(root)))
print(f'Packaged {len(files)} files; no local configuration, credentials or patient data.')
