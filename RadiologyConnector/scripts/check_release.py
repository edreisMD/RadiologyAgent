#!/usr/bin/env python3
"""Check connector source for accidental private data before a Git push."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
excluded = {'node_modules', '.venv', '__pycache__', '.pytest_cache', 'build', 'dist', '.git'}
bad = []
count = 0
for path in root.rglob('*'):
    if not path.is_file() or any(p in excluded for p in path.relative_to(root).parts):
        continue
    count += 1
    raw = path.read_bytes()
    if (path.name.startswith('.env') or path.suffix.lower() in {'.dcm', '.dicom', '.sqlite', '.sqlite3', '.db', '.docx'}
        or len(raw) > 132 and raw[128:132] == b'DICM'
        or re.search(rb'(?:sk-proj-|sk-ant-|ghp_|github_pat_)[A-Za-z0-9_-]{25,}', raw)):
        bad.append(str(path.relative_to(root)))
if bad:
    raise SystemExit('Private data or credential-shaped content rejected in: ' + ', '.join(bad))
print(f'PASS: {count} connector source files checked; no credential-shaped content, DICOM, reports or runtime databases.')
