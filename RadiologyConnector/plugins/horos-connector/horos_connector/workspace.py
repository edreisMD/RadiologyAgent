"""Shared, durable image workspace. The browser and MCP use the same renderer/state."""
from __future__ import annotations
import base64
from contextlib import contextmanager
import fcntl
import io
import json
import math
from pathlib import Path
import re
import time
from PIL import Image, ImageDraw, ImageOps
from .engine import Horos, fingerprint
from .storage import data_root, digest, write_json

SIZE = 1280
DEFAULT_VIEW = dict(image_index=0, window_width=None, window_center=None, zoom=1.0,
                    pan_x=0.0, pan_y=0.0, rotation=0, invert=False, region=None)


class Workspace:
    def __init__(self, engine=None):
        self.engine = engine or Horos()

    def folder(self, session_id):
        if not re.fullmatch(r"[a-f0-9]{32}", session_id):
            raise ValueError("Invalid workspace ID.")
        return data_root() / "workspaces" / session_id

    @contextmanager
    def locked(self, session_id):
        folder = self.folder(session_id)
        if not folder.is_dir(): raise ValueError("Unknown workspace.")
        with (folder / "lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield folder

    def read(self, session_id):
        return json.loads((self.folder(session_id) / "state.json").read_text())

    def open(self, study_uid=None, detail=None):
        detail = detail or self.engine.study(study_uid)
        session_id = digest([detail["study"]["studyUID"], fingerprint(detail)])[:32]
        folder = self.folder(session_id); folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.locked(session_id):
            if (folder / "state.json").exists(): return self.read(session_id)
            indices = [f["index"] for s in detail["series"] for f in s["frames"]]
            if not indices: raise ValueError("Study has no local images.")
            view = dict(DEFAULT_VIEW, image_index=indices[0])
            image, view = self.render(detail, view)
            file = self.save_image(folder, image)
            state = dict(session_id=session_id, revision=1, detail=detail, follow=True,
                         agent_view=view, user_view=view, agent_image=file, user_image=file,
                         actor="system", note="Study opened", updated=time.time(),
                         document="", document_revision=0, key_images=[], report_path=None,
                         events=[], thread_id=None)
            self.commit(folder, state)
            return state

    def save_image(self, folder, image):
        out = io.BytesIO(); image.save(out, format="PNG")
        import hashlib
        name = hashlib.sha256(out.getvalue()).hexdigest()[:32]+".png"
        path = folder / name
        if not path.exists():
            # Readers see this name only after the atomic state commit.
            path.write_bytes(out.getvalue()); path.chmod(0o600)
        return name

    def render(self, detail, view):
        hit = next(((s, f) for s in detail["series"] for f in s["frames"] if f["index"] == view["image_index"]), None)
        if not hit: raise ValueError("Image index is outside this study.")
        series, frame = hit
        image, info = self.engine.render(detail["study"]["id"], frame["id"], view["window_width"], view["window_center"])
        view = dict(view, series_uid=series["uid"], series_name=series["name"],
                    sop_instance_uid=frame.get("sopInstanceUID"), dicom_frame=frame["frame"],
                    effective_width=info["windowWidth"], effective_center=info["windowCenter"])
        if view["invert"]: image = ImageOps.invert(image.convert("RGB"))
        if view["rotation"]: image = image.rotate(-view["rotation"], expand=True)
        scale = min(SIZE/image.width, SIZE/image.height)*view["zoom"]
        # Affine sampling avoids allocating enormous intermediate images when zoomed.
        left = (SIZE-image.width*scale)/2 + view["pan_x"]*SIZE
        top = (SIZE-image.height*scale)/2 + view["pan_y"]*SIZE
        image = image.transform((SIZE,SIZE), Image.Transform.AFFINE,
                                (1/scale,0,-left/scale,0,1/scale,-top/scale),
                                Image.Resampling.BICUBIC, fillcolor=(0,0,0))
        if view["region"]:
            x,y,w,h = view["region"]
            ImageDraw.Draw(image).rectangle((x*SIZE,y*SIZE,(x+w)*SIZE,(y+h)*SIZE), outline="#eeeeee", width=3)
        return image, view

    def commit(self, folder, state):
        write_json(folder / "state.json", state)

    def action(self, session_id, changes, actor="agent", note="", expected_revision=None):
        if actor not in {"agent", "radiologist"}: raise ValueError("Invalid actor.")
        if not isinstance(note,str) or len(note)>400: raise ValueError("Note too long.")
        allowed = set(DEFAULT_VIEW) | {"follow", "reset", "step"}
        if not isinstance(changes,dict) or not set(changes)<=allowed: raise ValueError("Unsupported viewer action.")
        with self.locked(session_id) as folder:
            state = self.read(session_id)
            if expected_revision is not None and expected_revision != state["revision"]:
                raise ValueError("Workspace changed. Read the latest state before applying this action.")
            field = "agent_view" if actor=="agent" else "user_view"
            view = dict(state["agent_view"] if actor=="radiologist" and state["follow"] else state[field])
            changes = dict(changes)
            if "follow" in changes:
                if actor!="radiologist" or type(changes["follow"]) is not bool:
                    raise ValueError("Only the radiologist can change follow mode.")
                state["follow"] = changes.pop("follow")
            elif actor=="radiologist": state["follow"] = False
            if changes.pop("reset", False): view = dict(DEFAULT_VIEW, image_index=view["image_index"])
            if "step" in changes:
                step=changes.pop("step")
                if type(step) is not int or abs(step)>10000: raise ValueError("Invalid slice step.")
                series=next(s for s in state["detail"]["series"] if any(f["index"]==view["image_index"] for f in s["frames"]))
                indices=[f["index"] for f in series["frames"]]
                changes["image_index"]=indices[max(0,min(len(indices)-1,indices.index(view["image_index"])+step))]
            if "image_index" in changes:
                if type(changes["image_index"]) is not int: raise ValueError("Image index must be an integer.")
                series=next((s for s in state["detail"]["series"] if any(f["index"]==changes["image_index"] for f in s["frames"])),None)
                if not series: raise ValueError("Image index is outside this study.")
                if series["uid"] != view.get("series_uid"):
                    view=dict(DEFAULT_VIEW, image_index=changes["image_index"])
                else: view["region"]=None
            view.update(changes)
            for key,low,high in [("zoom",0.2,8),("pan_x",-3,3),("pan_y",-3,3)]:
                v=view[key]
                if not isinstance(v,(int,float)) or not math.isfinite(v) or not low<=v<=high:
                    raise ValueError("Invalid "+key)
            if view["rotation"] not in {0,90,180,270} or type(view["invert"]) is not bool:
                raise ValueError("Invalid presentation.")
            region=view["region"]
            if region is not None and (not isinstance(region,list) or len(region)!=4 or
                 not all(isinstance(v,(float,int)) and math.isfinite(v) and 0<=v<=1 for v in region) or
                 region[2]<=0 or region[3]<=0 or region[0]+region[2]>1 or region[1]+region[3]>1):
                raise ValueError("Region must be normalized viewport [x,y,width,height].")
            image, view = self.render(state["detail"],view)
            state[field]=view; state["agent_image" if actor=="agent" else "user_image"]=self.save_image(folder,image)
            state.update(revision=state["revision"]+1, actor=actor, note=note or "View updated", updated=time.time())
            event=dict(revision=state["revision"],actor=actor,note=state["note"],view=view,
                       image=state["agent_image" if actor=="agent" else "user_image"],time=state["updated"])
            state["events"]=(state["events"]+[event])[-200:]
            self.commit(folder,state)
            return state

    def document(self, session_id, document, key_images, expected_revision, actor="agent"):
        if not isinstance(document,str) or not 0<len(document)<=100000: raise ValueError("Invalid document.")
        if not isinstance(key_images,list) or len(key_images)>100: raise ValueError("Too many key images.")
        with self.locked(session_id) as folder:
            state=self.read(session_id)
            if expected_revision!=state["document_revision"]: raise ValueError("Report was edited. Read and reconcile the current document before saving.")
            indices={f["index"] for s in state["detail"]["series"] for f in s["frames"]}
            clean=[]
            for link in key_images:
                if not isinstance(link,dict) or set(link)!={"phrase","image_index"}: raise ValueError("Key image requires phrase and image_index.")
                if not isinstance(link["phrase"],str) or not link["phrase"] or link["phrase"] not in document or type(link["image_index"]) is not int or link["image_index"] not in indices:
                    raise ValueError("Key image must reference an exact report phrase and a frame in this study.")
                clean.append(link)
            if state["document"]:
                write_json(folder/"report-history"/(str(state["document_revision"])+".json"),{k:state[k] for k in ["document","key_images","document_revision","updated","actor"]})
            state.update(document=document,key_images=clean,document_revision=state["document_revision"]+1,
                         revision=state["revision"]+1,actor=actor,note="Draft updated",updated=time.time())
            self.commit(folder,state)
            return state

    def snapshot(self, session_id, actor="display"):
        state=self.read(session_id)
        which="agent" if actor=="agent" or (actor=="display" and state["follow"]) else "user"
        return state, (self.folder(session_id)/state[which+"_image"]).read_bytes()

    def public(self, state):
        """No native object handles, local file paths, or credentials enter the browser."""
        from .privacy import public_study,series_name,demo_mode
        study=public_study(state["detail"]["study"])
        visible={k:v for k,v in state.items() if k not in {"detail","report_path"}}
        if demo_mode():
            names={s['uid']:series_name(s,i) for i,s in enumerate(state['detail']['series'])}
            for field in ['agent_view','user_view']:
                visible[field]=dict(state[field],series_name=names[state[field]['series_uid']])
            visible['events']=[dict(event,view=dict(event['view'],series_name=names[event['view']['series_uid']])) for event in state['events']]
        return visible | {
            "study":{k:study.get(k) for k in ["studyUID","patientName","patientID","title","date","accession","modality"]},
            "series":[{"name":series_name(s,i),"uid":s["uid"],"modality":s["modality"],"indices":[f["index"] for f in s["frames"]]} for i,s in enumerate(state["detail"]["series"])],
            "frame_count":state["detail"]["frameCount"],"demo_display_aliases":demo_mode()}
