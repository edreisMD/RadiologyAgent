import base64
import json
import threading
import urllib.request
import urllib.error
import pytest
from test_connector import detail, FakeEngine, isolated
from horos_connector.workspace import Workspace
from horos_connector.dispatch import Dispatcher
from horos_connector.queue import Queue
from horos_connector.workspace_service import Handler, ThreadingHTTPServer


def test_shared_view_is_exact_and_radiologist_can_pause_agent(isolated):
    ws=Workspace(FakeEngine()); state=ws.open(detail=detail()); sid=state["session_id"]
    agent=ws.action(sid,{"image_index":1},note="Inspecting next slice")
    assert ws.snapshot(sid)[1]==ws.snapshot(sid,"agent")[1]
    user=ws.action(sid,{"image_index":2},actor="radiologist")
    pinned=ws.snapshot(sid)[1]
    agent=ws.action(sid,{"image_index":0},note="Inspecting first slice")
    assert not agent["follow"] and ws.snapshot(sid)[1]==pinned
    assert ws.snapshot(sid,"agent")[1]!=pinned
    restored=ws.action(sid,{"follow":True},actor="radiologist")
    assert restored["follow"] and ws.snapshot(sid)[1]==ws.snapshot(sid,"agent")[1]
    assert Workspace(FakeEngine()).open(detail=detail())["revision"]==restored["revision"]


def test_invalid_actions_and_stale_updates_leave_view_unchanged(isolated):
    ws=Workspace(FakeEngine());initial=ws.open(detail=detail());sid=initial["session_id"]
    for changes in [{"image_index":999},{"zoom":float("nan")},{"pan_x":9},{"region":[.8,0,.8,1]},{"follow":True},{"rotation":45}]:
        with pytest.raises(ValueError):ws.action(sid,changes)
        assert ws.read(sid)["revision"]==1
    ws.action(sid,{"zoom":2})
    with pytest.raises(ValueError):ws.action(sid,{"zoom":3},expected_revision=1)
    assert ws.read(sid)["agent_view"]["zoom"]==2


def test_report_edits_conflict_and_links_cannot_cross_studies(isolated):
    ws=Workspace(FakeEngine());sid=ws.open(detail=detail())["session_id"]
    ws.document(sid,"FINDINGS\nExample sentence.",[{"phrase":"Example sentence.","image_index":1}],0)
    ws.document(sid,"Radiologist changed this.",[],1,actor="radiologist")
    with pytest.raises(ValueError):ws.document(sid,"Agent stale draft",[],1)
    with pytest.raises(ValueError):ws.document(sid,"Some text",[{"phrase":"text","image_index":999}],2)
    assert ws.read(sid)["document"]=="Radiologist changed this."


def test_dispatch_outbox_survives_uncertain_creation_and_enforces_one_task(isolated):
    q=Queue();job=q.enqueue(detail());q.update(job,state="ready");d=Dispatcher(q)
    first=d.reserve();assert first["job_id"]==job and first["reserved"]
    assert not Dispatcher(q).reserve()["reserved"]
    thread="01a08309-997c-7ea1-bf7d-2aeef4c05f87"
    d.attach(job,first["reservation_token"],thread)
    d.attach(job,first["reservation_token"],thread)
    with pytest.raises(ValueError):d.attach(job,first["reservation_token"],"11a08309-997c-7ea1-bf7d-2aeef4c05f87")
    assert d.list_runs()[0]["thread_id"]==thread
    assert not d.reserve()["reserved"]


def test_dispatch_limits_concurrency_and_reconciles_existing_task(isolated):
    q=Queue();d=Dispatcher(q)
    for i in range(3):
        job=q.enqueue(detail(str(i)));q.update(job,state="ready")
    a=d.reserve();b=d.reserve();assert a["reserved"] and b["reserved"]
    assert not d.reserve()["reserved"]
    d.recover(a["job_id"],"01a08309-997c-7ea1-bf7d-2aeef4c05f87")
    q.update(a["job_id"],state="drafted")
    assert d.reserve()["reserved"]


def test_http_requires_auth_and_rejects_cross_origin_and_rebinding(isolated,monkeypatch):
    import horos_connector.workspace_service as svc
    monkeypatch.setattr(svc,"ui_call",lambda method,args:{"ok":True})
    server=ThreadingHTTPServer(("127.0.0.1",0),Handler);server.token="a"*64
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    url=f"http://127.0.0.1:{server.server_port}"
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        assert opener.open(url).status==200
        for headers in [{},{"Authorization":"Bearer "+server.token,"Origin":"https://example.com"},{"Authorization":"Bearer "+server.token,"Host":"evil.example"}]:
            with pytest.raises(urllib.error.HTTPError) as exc:opener.open(urllib.request.Request(url+"/health",headers=headers))
            assert exc.value.code==403
        req=urllib.request.Request(url+"/api",data=b'{"method":"state"}',headers={"Authorization":"Bearer "+server.token,"Content-Type":"application/json"})
        response=opener.open(req);assert json.load(response)=={"ok":True}
        assert response.headers["Cache-Control"]=="no-store"
        assert "\'unsafe-eval\'" not in response.headers["Content-Security-Policy"]
    finally:server.shutdown();server.server_close()


def test_inspect_tool_returns_same_pixels_and_cropped_view_does_not_count(isolated,monkeypatch):
    import horos_connector.server as server
    monkeypatch.setattr(server,"Workspace",lambda:Workspace(FakeEngine()))
    ws=Workspace(FakeEngine());d=detail();sid=ws.open(detail=d)["session_id"]
    q=Queue();job=q.enqueue(d);q.update(job,state="ready");claim=q.claim(job)
    result=server.inspect_view(sid,{"image_index":1},job_id=job,claim_token=claim["claim_token"],require_browser=False)
    assert base64.b64decode(result.content[1].data)==ws.snapshot(sid)[1]
    assert q.get(job)["reviewed"]==[1]
    server.inspect_view(sid,{"image_index":2,"zoom":2},job_id=job,claim_token=claim["claim_token"],require_browser=False)
    assert q.get(job)["reviewed"]==[1]
    other=q.enqueue(detail("other"));q.update(other,state="ready");token=q.claim(other)["claim_token"]
    with pytest.raises(ValueError):server.inspect_view(sid,{},job_id=other,claim_token=token)
