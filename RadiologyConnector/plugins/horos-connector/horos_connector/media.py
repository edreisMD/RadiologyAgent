from __future__ import annotations
import fcntl
import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from .storage import data_root, digest, write_json
from .engine import fingerprint


def manifest_path(uid: str, revision: str) -> Path:
    return data_root() / "media" / digest(uid)[:20] / revision[:20] / "manifest.json"


def frame_list(detail: dict):
    return [f for s in detail["series"] for f in s["frames"]]


def contact_sheet(paths: list[Path], labels: list[str], output: Path):
    cell_w, cell_h, columns = 384, 416, 3
    rows = (len(paths) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * cell_w, rows * cell_h), "#101115")
    draw = ImageDraw.Draw(sheet); font = ImageFont.load_default(size=16)
    for index, (path, label) in enumerate(zip(paths, labels)):
        with Image.open(path) as source:
            image = source.convert("RGB"); image.thumbnail((cell_w - 12, cell_h - 38))
            x, y = (index % columns) * cell_w, (index // columns) * cell_h
            sheet.paste(image, (x + (cell_w-image.width)//2, y + 5))
            draw.text((x+10, y+cell_h-27), label, fill="white", font=font)
    sheet.save(output)


def make_video(paths: list[Path], output: Path, fps=8):
    executable = shutil.which("ffmpeg") or next((p for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] if Path(p).is_file()), None)
    if not executable: raise RuntimeError("Install ffmpeg to generate CT/MR cine videos.")
    first = Image.open(paths[0]); width, height = first.size
    width += width % 2; height += height % 2
    # All frames are included, with equal timing and no interpolation. Fixed canvas
    # avoids dropping frames in series that contain mixed image dimensions.
    command = [executable, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{width}x{height}", "-r", str(fps), "-i", "-", "-an", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for path in paths:
            with Image.open(path) as source:
                image = source.convert("RGB"); image.thumbnail((width, height))
                canvas = Image.new("RGB", (width, height), "black")
                canvas.paste(image, ((width-image.width)//2, (height-image.height)//2))
                process.stdin.write(canvas.tobytes())
        process.stdin.close(); process.stdin = None
        _, error = process.communicate(timeout=180)
        if process.returncode: raise RuntimeError("Video encoding failed: " + error.decode()[-500:])
    except BaseException:
        process.kill(); process.wait(); raise


def export_study(engine, detail: dict, progress=lambda *args: None) -> dict:
    uid = detail["study"]["studyUID"]; revision = fingerprint(detail)
    target = manifest_path(uid, revision); target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (target.parent / ".export.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists():
            cached = json.loads(target.read_text())
            if cached.get("complete"): return cached
        result = {"study": detail["study"], "revision": revision, "frame_count": detail["frameCount"], "rendered_frames": 0, "complete": False, "series": [], "limitations": ["Cine playback preserves Horos frame order; it is not a reconstructed 3D volume.", "A complete export describes locally available frames, not proof of complete examination arrival.", "MP4 is a lossy navigation aid. Review PNG frames and adjust windows for diagnostic detail."]}
        for position, series in enumerate(detail["series"]):
            directory = target.parent / f"series-{position:04d}"; directory.mkdir(exist_ok=True, mode=0o700)
            entry = {"id": series["id"], "uid": series["uid"], "name": series["name"], "modality": series["modality"], "frames": [], "contact_sheets": [], "videos": []}
            for index, frame in enumerate(series["frames"]):
                path = directory / f"frame-{index:06d}.png"
                image, render = engine.render(detail["study"]["id"], frame["id"])
                image.save(path); os.chmod(path, 0o600)
                entry["frames"].append({**frame, "path": str(path), "render": render})
                result["rendered_frames"] += 1
                progress(result["rendered_frames"], detail["frameCount"])
            paths = [Path(f["path"]) for f in entry["frames"]]
            for offset in range(0, len(paths), 12):
                output = directory / f"contact-{offset//12:04d}.png"
                subset = entry["frames"][offset:offset+12]
                labels = [f"Image {f['index']} | Instance {f['instance']} | Frame {f['frame']}" for f in subset]
                contact_sheet(paths[offset:offset+12], labels, output)
                entry["contact_sheets"].append({"path": str(output), "image_indices": [f["index"] for f in subset]})
            if paths and len(paths) > 1 and series["modality"] in {"CT", "MR"}:
                # Bound each cine to 256 frames so Codex can work with one clip at a time.
                for offset in range(0, len(paths), 256):
                    output = directory / f"cine-{offset//256:04d}.mp4"
                    make_video(paths[offset:offset+256], output)
                    entry["videos"].append({"path": str(output), "fps": 8, "image_indices": [f["index"] for f in entry["frames"][offset:offset+256]]})
            result["series"].append(entry)
            write_json(target, result)
        result["complete"] = True; result["exported_at"] = time.time(); result["manifest_path"] = str(target)
        write_json(target, result)
        return result
