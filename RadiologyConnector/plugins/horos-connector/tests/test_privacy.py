import json
import pytest
from test_connector import detail, FakeEngine, isolated
from horos_connector.storage import write_json
from horos_connector.privacy import public_study,series_name
from horos_connector.workspace import Workspace
from horos_connector.dispatch import Dispatcher
from horos_connector.queue import Queue


def test_demo_aliases_are_stable_and_do_not_change_original_identity(isolated):
    write_json(isolated/'config.json',{'demo_display_aliases':True})
    a=detail();a['series'][0]['name']='Facility Scanner Protocol'
    original=dict(a['study']);alias=public_study(original)
    assert alias['patientName']=='Patient 001' and alias['patientID']=='DEMO-001'
    assert alias['studyUID']==original['studyUID'] and alias['accession'] is None and alias['date'] is None
    assert original['patientName']=='Example Patient'
    assert public_study(original)==alias
    assert public_study(detail('1.2.4')['study'])['patientName']=='Patient 002'
    ws=Workspace(FakeEngine());state=ws.open(detail=a);visible=ws.public(state)
    assert visible['series'][0]['name']=='CT series 01'
    assert visible['agent_view']['series_name']=='CT series 01'
    assert 'Facility Scanner Protocol' not in json.dumps(visible)
    assert ws.read(state['session_id'])['detail']['series'][0]['name']=='Facility Scanner Protocol'


def test_manual_run_can_reserve_preparing_job_but_scheduler_cannot(isolated):
    q=Queue();job=q.enqueue(detail());d=Dispatcher(q)
    assert not d.reserve()['reserved']
    with pytest.raises(ValueError):d.reserve(allow_preparing=True)
    assert d.reserve(job,allow_preparing=True)['reserved']
    q.update(job,state='ready')
    assert not d.reserve()['reserved']
