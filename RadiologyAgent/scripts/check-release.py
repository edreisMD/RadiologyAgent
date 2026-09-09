"""Check distributable code and app contents without printing credentials."""
from pathlib import Path
import re
root = Path(__file__).resolve().parent.parent
excluded = {'.git', '.build', '.venv', '.local', '__pycache__', '.pytest_cache', 'node_modules'}
problems = []
for path in root.rglob('*'):
    relative = path.relative_to(root)
    if any(part in excluded for part in relative.parts) or not path.is_file():
        continue
    if path.name == '.env' or path.name.endswith('.zip'):
        continue
    if path.suffix.lower() in {'.dcm', '.dicom', '.sqlite3'} or path.name in {'workspace.json', 'incoming-studies.json', 'api-token', 'engine-connection.json'}:
        problems.append(str(relative))
    if path.stat().st_size <= 20_000_000:
        data = path.read_bytes()
        if re.search(rb'sk-proj-[A-Za-z0-9_-]{40,}', data):
            problems.append(str(relative))
assert not problems, 'Release contains private material in: ' + ', '.join(problems)
assert '.env*' in (root / '.gitignore').read_text()
assert '.env*' in (root / '.dockerignore').read_text()
print('PASS: distributable source and app contain no API keys, DICOM files, or runtime databases.')
