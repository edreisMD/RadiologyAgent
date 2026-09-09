from __future__ import annotations
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path


def data_root() -> Path:
    path = Path(os.environ.get("RADAGENT_CONNECTOR_HOME", Path.home() / "Library/Application Support/RadAgent/connector")).expanduser()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".radagent-")
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(value, out, ensure_ascii=False, indent=2, allow_nan=False)
            out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def config() -> dict:
    path = data_root() / "config.json"
    return json.loads(path.read_text()) if path.exists() else {}


def component(text: str, fallback="Unknown", limit=90) -> str:
    text = re.sub(r'[\x00-\x1f\x7f/\\:*?"<>|]', " ", str(text))
    return (" ".join(text.split()).strip(" .")[:limit].strip() or fallback)


def contained(root: Path, child: Path) -> Path:
    result = child.resolve()
    if not result.is_relative_to(root.resolve()):
        raise ValueError("Artifact path must remain inside its configured directory.")
    return result
