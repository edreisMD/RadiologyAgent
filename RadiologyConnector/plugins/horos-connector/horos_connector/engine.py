from __future__ import annotations
import base64
import io
import json
import math
import os
import stat
import urllib.request
from pathlib import Path
from PIL import Image

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Horos redirects are not allowed.")

class Horos:
    def __init__(self, connection: Path | None = None):
        self.connection = connection or Path.home() / "Library/Application Support/RadAgent/engine-connection.json"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, route: str, body: dict | None = None) -> dict:
        if route not in {"/health", "/studies", "/study", "/render", "/dicom", "/open-series", "/pacs/nodes", "/pacs/retrieve"}:
            raise ValueError("Unsupported Horos action.")
        try:
            info = self.connection.stat()
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("Horos connection descriptor must be private to this account.")
            descriptor = json.loads(self.connection.read_text())
        except FileNotFoundError:
            raise RuntimeError("Open Horos with the Radiology Agent engine plugin installed to connect.") from None
        port, token = descriptor.get("port"), descriptor.get("token", "")
        if not isinstance(port, int) or not 1024 <= port <= 65535 or not isinstance(token, str) or len(token) < 24:
            raise ValueError("Invalid Horos connection descriptor.")
        if descriptor.get("protocolVersion") != 1:
            raise ValueError("Unsupported Horos engine protocol.")
        pid = descriptor.get("pid")
        if not isinstance(pid, int) or pid <= 0: raise ValueError("Invalid Horos process.")
        os.kill(pid, 0)
        request = urllib.request.Request(f"http://127.0.0.1:{port}{route}", data=json.dumps(body or {}, allow_nan=False).encode(), headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with self.opener.open(request, timeout=90) as response:
            raw = response.read(100_000_001)
            if len(raw) > 100_000_000: raise ValueError("Engine response exceeded the supported size.")
        result = json.loads(raw)
        if "error" in result: raise RuntimeError(result["error"])
        return result

    def studies(self, search="") -> list[dict]:
        result = []
        for offset in range(0, 100_000, 200):
            page = self.call("/studies", {"search": search, "offset": offset, "limit": 200})
            result.extend(page["studies"])
            if not page.get("hasMore") or not page["studies"]: return result
        raise RuntimeError("Library exceeds 100,000 studies; choose a narrower worklist.")

    def study(self, uid: str) -> dict:
        hits = [s for s in self.studies() if s["studyUID"] == uid]
        if len(hits) != 1: raise ValueError("Study UID must identify exactly one study in the active Horos database.")
        return self.call("/study", {"id": hits[0]["id"]})

    def render(self, study_id: str, image_id: str, width=None, center=None, max_side=2048):
        if (width is None) != (center is None): raise ValueError("Supply both window width and center.")
        if width is not None and (not all(math.isfinite(v) for v in [width, center]) or not 1 <= width <= 1e6 or abs(center) > 1e6):
            raise ValueError("Invalid window settings.")
        if not 256 <= max_side <= 4096: raise ValueError("Image size must be 256–4096 pixels.")
        args = {"studyID": study_id, "imageID": image_id}
        if width is not None: args.update(width=width, center=center)
        render = self.call("/render", args)
        image = Image.open(io.BytesIO(base64.b64decode(render.pop("png"), validate=True)))
        image.load(); image = image.convert("RGB")
        image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
        return image, render


def fingerprint(detail: dict) -> str:
    from .storage import digest
    return digest({"uid": detail["study"]["studyUID"], "series": [{"uid": s["uid"], "frames": [(f.get("sopInstanceUID"), f.get("frame"), f.get("instance"), f.get("width"), f.get("height")) for f in s["frames"]]} for s in detail["series"]]})
