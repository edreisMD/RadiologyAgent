"""Authenticated local transport for the shared Radiology Agent browser workspace."""
from __future__ import annotations
import base64
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import mimetypes
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit, parse_qs
from .engine import Horos
from .storage import data_root, write_json
from .workspace import Workspace, DEFAULT_VIEW

WEB = Path(__file__).parent / "web"


def ui_call(method, args):
    ws=Workspace()
    if method=="worklist":
        search=args.get("search", "")
        if not isinstance(search,str) or len(search)>200: raise ValueError("Invalid search.")
        from .queue import Queue
        jobs={j["uid"]:j for j in Queue().jobs(("pending","exporting","ready","processing","drafted","error"))}
        from .dispatch import Dispatcher
        runs={r["job_id"]:r for r in Dispatcher().list_runs()}
        studies=Horos().studies(search)[:200]
        result=[]
        from .privacy import public_study
        for study in studies:
            job=jobs.get(study["studyUID"]); run=runs.get(job["id"]) if job else None
            study=public_study(study)
            result.append({k:study.get(k) for k in ["studyUID","patientName","patientID","title","date","modality"]} |
                          {"status":job["state"] if job else "In Horos", "thread_id":run.get("thread_id") if run else None})
        return {"studies":result, "limited_to":200}
    if method=="open": return ws.public(ws.open(args["study_uid"]))
    session_id=args["session_id"]
    if method=="dicom_manifest":
        from .dicom import manifest
        return manifest(session_id)
    if method=="rendered":
        state=ws.read(session_id)
        renderer=args.get("renderer","Cornerstone3D")
        if renderer not in {"Cornerstone3D", "Horos preview"}:raise ValueError("Unknown renderer.")
        if args["revision"]!=state["revision"]:return {"accepted":False}
        png=base64.b64decode(args["png"],validate=True)
        if len(png)>10000000:raise ValueError("Viewport capture too large.")
        from PIL import Image
        image=Image.open(io.BytesIO(png));image.load()
        if image.width>4096 or image.height>4096 or image.width<64 or image.height<64:raise ValueError("Invalid viewport dimensions.")
        image_name=ws.save_image(ws.folder(session_id),image.convert("RGB"))
        write_json(ws.folder(session_id)/"browser-render.json",{"revision":state["revision"],"image":image_name,"follow":state["follow"],"time":time.time(),"renderer":renderer})
        return {"accepted":True}
    if method=="state":
        state=ws.read(session_id)
        if args.get("since")==state["revision"]: return {"unchanged":True}
        return ws.public(state)
    if method=="agent_action":
        return ws.public(ws.action(session_id,args["changes"],"agent",args.get("note","Codex inspecting"),args.get("expected_revision")))
    if method=="agent_document":
        return ws.public(ws.document(session_id,args["document"],args.get("key_images",[]),args["expected_revision"],"agent"))
    if method=="action":
        return ws.public(ws.action(session_id,args["changes"],"radiologist",args.get("note","Radiologist inspecting"),args.get("expected_revision")))
    if method=="document":
        return ws.public(ws.document(session_id,args["document"],[],args["expected_revision"],"radiologist"))
    if method=="image":
        name=args["name"]
        if not re.fullmatch(r"[a-f0-9]{32}\.png",name): raise ValueError("Invalid image.")
        return {"png":base64.b64encode((ws.folder(session_id)/name).read_bytes()).decode()}
    if method=="preview":
        state=ws.read(session_id)
        index=args["image_index"]
        if type(index) is not int: raise ValueError("Invalid image index.")
        view=dict(DEFAULT_VIEW,image_index=index)
        image,view=ws.render(state["detail"],view)
        if args.get("thumbnail"): image.thumbnail((160,160))
        out=io.BytesIO();image.save(out,format="PNG")
        return {"png":base64.b64encode(out.getvalue()).decode(),"view":view}
    if method=="native":
        state=ws.read(session_id);view=state["agent_view"] if state["follow"] else state["user_view"]
        series=next(s for s in state["detail"]["series"] if s["uid"]==view["series_uid"])
        frame=next(f for f in series["frames"] if f["index"]==view["image_index"])
        return Horos().call("/open-series",{"studyID":state["detail"]["study"]["id"],"seriesID":series["id"],"imageID":frame["id"],"width":view["effective_width"],"center":view["effective_center"]})
    raise ValueError("Unsupported workspace operation.")


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass # URL/query data must not enter logs.

    def reply(self,code,data,content_type="application/json",decoder_worker=False):
        if not isinstance(data,bytes): data=json.dumps(data,allow_nan=False).encode()
        self.send_response(code)
        # Emscripten's pinned codec bindings generate functions inside this worker.
        # Keep eval disabled in the document and every other asset/context.
        script_policy="'self' 'unsafe-eval'" if decoder_worker else "'self' 'wasm-unsafe-eval'"
        for k,v in {"Content-Type":content_type,"Content-Length":str(len(data)),"Cache-Control":"no-store",
                    "X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer",
                    "Content-Security-Policy":f"default-src 'none'; script-src {script_policy}; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"}.items(): self.send_header(k,v)
        self.end_headers();self.wfile.write(data)

    def trusted_host(self):
        return self.headers.get("Host")==f"127.0.0.1:{self.server.server_port}"

    def authorized(self):
        origin=self.headers.get("Origin")
        if origin and origin!=f"http://127.0.0.1:{self.server.server_port}": return False
        return self.trusted_host() and secrets.compare_digest(self.headers.get("Authorization","").encode(),("Bearer "+self.server.token).encode())

    def do_GET(self):
        if not self.trusted_host(): return self.reply(403,{"error":"Invalid host."})
        path=urlsplit(self.path).path
        build=WEB/"build"
        if path=="/" and (build/"index.html").is_file():return self.reply(200,(build/"index.html").read_bytes(),"text/html; charset=utf-8")
        if path.startswith("/assets/"):
            file=(build/path.lstrip("/")).resolve()
            if not file.is_relative_to((build/"assets").resolve()) or not file.is_file():return self.reply(404,{"error":"Missing viewer asset."})
            return self.reply(200,file.read_bytes(),mimetypes.guess_type(file.name)[0] or "application/octet-stream",decoder_worker=bool(re.fullmatch(r"decodeImageFrameWorker-[A-Za-z0-9_-]+\.js",file.name)))
        static={"/":("index.html","text/html; charset=utf-8"),"/app.js":("app.js","application/javascript"),"/style.css":("style.css","text/css")}
        if path in static:
            name,mime=static[path];return self.reply(200,(WEB/name).read_bytes(),mime)
        if not self.authorized(): return self.reply(403,{"error":"Workspace authorization required."})
        if path.startswith("/dicom/"):
            try:
                from .dicom import file_path
                parts=path.strip("/").split("/")
                if len(parts)!=3:raise ValueError("Invalid DICOM path.")
                return self.reply(200,file_path(parts[1],parts[2].removesuffix(".dcm")).read_bytes(),"application/dicom")
            except (ValueError,FileNotFoundError):return self.reply(404,{"error":"DICOM instance unavailable."})
        if path=="/health": return self.reply(200,{"running":True,"protocol":1})
        return self.reply(404,{"error":"Unknown route."})

    def do_POST(self):
        if not self.authorized(): return self.reply(403,{"error":"Workspace authorization required."})
        if urlsplit(self.path).path!="/api": return self.reply(404,{"error":"Unknown route."})
        try:
            length=int(self.headers.get("Content-Length","0"))
            if not 0<length<=15000000: raise ValueError("Invalid request size.")
            if self.headers.get("Content-Type")!="application/json": raise ValueError("Expected JSON.")
            body=json.loads(self.rfile.read(length))
            result=ui_call(body["method"],body.get("args",{}))
            self.reply(200,result)
        except (ValueError,KeyError,FileNotFoundError,RuntimeError) as exc:
            self.reply(409,{"error":str(exc)[:250]})
        except Exception:
            self.reply(503,{"error":"Horos or workspace is unavailable. Check the connector status."})


def connection():
    path=data_root()/"workspace-connection.json"
    info=path.stat()
    if info.st_uid!=os.getuid() or info.st_mode&0o077: raise ValueError("Workspace descriptor is not private.")
    d=json.loads(path.read_text())
    if d.get("protocol")!=1 or type(d.get("port")) is not int or not 1024<=d["port"]<=65535 or not re.fullmatch(r"[a-f0-9]{64}",d.get("token","")):
        raise ValueError("Invalid workspace connection.")
    return d


def ensure_service():
    def available():
        try:
            d=connection()
            request=urllib.request.Request(f'http://127.0.0.1:{d["port"]}/health',headers={"Authorization":"Bearer "+d["token"]})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=1) as response:
                if json.load(response).get("protocol")==1: return d
        except (OSError,ValueError): pass
    with (data_root()/"workspace-start.lock").open("a+") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        d=available()
        if d: return d
        env=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parents[1]))
        with (data_root()/"workspace.stderr.log").open("ab") as log:
            subprocess.Popen([sys.executable,"-m","horos_connector.workspace_service"],env=env,
                             stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=log,start_new_session=True)
        for _ in range(40):
            d=available()
            if d:return d
            time.sleep(.1)
        raise RuntimeError("Workspace service did not start. Inspect its private error log.")


def workspace_url(session_id=""):
    d=ensure_service()
    return f'http://127.0.0.1:{d["port"]}/#token={d["token"]}&session={session_id}'


def main():
    os.umask(0o077)
    with (data_root()/"workspace-server.lock").open("a+") as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return
        try:previous=connection()
        except (OSError,ValueError):previous={}
        server=ThreadingHTTPServer(("127.0.0.1",previous.get("port",0)),Handler)
        server.daemon_threads=True;server.token=previous.get("token") or secrets.token_hex(32)
        write_json(data_root()/"workspace-connection.json",dict(port=server.server_port,token=server.token,pid=os.getpid(),protocol=1))
        server.serve_forever()

if __name__=="__main__":main()
