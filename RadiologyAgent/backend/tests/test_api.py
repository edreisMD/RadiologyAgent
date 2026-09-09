from pathlib import Path
from fastapi.testclient import TestClient
from backend.app import create_app

TOKEN = 'test-credential-not-a-secret-' * 2

def client(tmp_path):
    return TestClient(create_app(tmp_path, TOKEN), headers={'Authorization': f'Bearer {TOKEN}'})

def study(**extra):
    return {'study_uid': '1.2.3.4', 'patient_id': 'research-1', 'patient_name': 'Synthetic API fixture', 'description': 'Chest', 'modality': 'CR', **extra}

def test_auth_and_origin(tmp_path):
    c = TestClient(create_app(tmp_path, TOKEN))
    assert c.get('/v1/studies').status_code == 401
    assert c.post('/v1/studies', headers={'Authorization': f'Bearer {TOKEN}', 'Origin': 'https://example.invalid'}, json=study()).status_code == 403
    assert c.get('/health').json()['status'] == 'ok'

def test_idempotency_and_patient_identity(tmp_path):
    c = client(tmp_path)
    a = c.post('/v1/studies', json=study(), headers={'Idempotency-Key': 'arrival-1'})
    b = c.post('/v1/studies', json=study(), headers={'Idempotency-Key': 'arrival-1'})
    assert a.status_code == 200 and a.json() == b.json()
    assert c.post('/v1/studies', json=study(description='Different'), headers={'Idempotency-Key': 'arrival-1'}).status_code == 409
    assert c.post('/v1/studies', json=study(patient_id='different-patient')).status_code == 409
    assert c.get('/v1/studies').json()['total'] == 1

def test_stable_tag_queues_draft_and_revision_conflict(tmp_path):
    c = client(tmp_path)
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=False)).json()
    assert item['status'] == 'new'
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=True)).json()
    assert item['status'] == 'queued'
    assert c.patch('/v1/studies/1.2.3.4', json={'priority': 'urgent', 'expected_revision': 1}).status_code == 409
    assert c.patch('/v1/studies/1.2.3.4', json={'priority': 'urgent', 'expected_revision': item['revision']}).status_code == 200

def test_draft_versions_and_no_finalization(tmp_path):
    c = client(tmp_path)
    c.post('/v1/studies', json=study())
    for version in range(2):
        response = c.put('/v1/studies/1.2.3.4/draft', json={'document': f'Draft {version}', 'expected_revision': version})
        assert response.status_code == 200
        assert response.json()['purpose'] == 'Draft for evaluation'
    assert c.put('/v1/studies/1.2.3.4/draft', json={'document': 'stale', 'expected_revision': 0}).status_code == 409
    assert len(c.get('/v1/studies/1.2.3.4/draft/versions').json()['versions']) == 2
    assert c.post('/v1/studies/1.2.3.4/finalize').status_code == 404
    assert c.get('/v1/studies').json()['studies'][0]['status'] == 'draft'

def test_templates_validate_versions_and_persist(tmp_path):
    c = client(tmp_path)
    template = {'id': 'chest', 'name': 'Chest', 'document': 'FINDINGS\n[Observed findings]', 'modalities': ['CR'], 'keywords': ['chest']}
    assert c.put('/v1/templates/chest', json=template).status_code == 200
    assert c.put('/v1/templates/chest', json=template).status_code == 409
    reopened = client(tmp_path)
    assert reopened.get('/v1/templates').json()['templates'][0]['name'] == 'Chest'
    assert (tmp_path / 'worklist.sqlite3').stat().st_mode & 0o777 == 0o600

def test_limits_and_extra_fields(tmp_path):
    c = client(tmp_path)
    assert c.post('/v1/studies', json=study(finalize=True)).status_code == 422
    assert c.post('/v1/studies', json=study(study_uid='file:///tmp/example')).status_code == 422
    assert c.post('/v1/studies', content=b'x' * 1_000_001).status_code == 413
    assert c.get('/v1/studies?limit=10000').status_code == 422

def test_two_workers_cannot_claim_same_study(tmp_path):
    c = client(tmp_path)
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=True)).json()
    claim = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'worker-a', 'expected_revision': item['revision']})
    assert claim.status_code == 200
    arrival = c.post('/v1/studies', json={'study_uid':'1.2.3.4','received_complete':True}).json()
    assert arrival['lease_expires'] == claim.json()['lease_expires']
    assert arrival['claimed_by'] == 'worker-a'
    assert c.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'worker-b', 'expected_revision': arrival['revision']}).status_code == 409

def test_partial_arrival_does_not_erase_identity_or_draft(tmp_path):
    c = client(tmp_path)
    c.post('/v1/studies', json=study())
    c.put('/v1/studies/1.2.3.4/draft', json={'document': 'Preserved report', 'expected_revision': 0})
    assert c.post('/v1/studies', json={'study_uid': '1.2.3.4', 'received_complete': True}).status_code == 200
    value = c.get('/v1/studies').json()['studies'][0]
    assert value['patient_id'] == 'research-1'
    assert c.get('/v1/studies/1.2.3.4/draft').json()['document'] == 'Preserved report'

def test_orthanc_mapping_and_https_requirement():
    from backend.integrations.orthanc_bridge import payload_for, validate_url
    value = payload_for({'MainDicomTags': {'StudyInstanceUID': '1.2.3', 'StudyDescription': 'Chest'}, 'Labels': ['radagent-draft']}, {'MainDicomTags': {'PatientName': 'Fixture^Only', 'PatientID': 'test'}})
    assert value['study_uid'] == '1.2.3' and value['patient_name'] == 'Fixture Only'
    assert value['tags'] == ['radagent-draft']
    import pytest
    with pytest.raises(ValueError):
        validate_url('http://clinic.example')
    with pytest.raises(ValueError):
        validate_url('https://user:pass@clinic.example')

def test_evidence_cannot_link_another_patient_or_missing_phrase(tmp_path):
    c = client(tmp_path)
    c.post('/v1/studies', json=study())
    evidence = {'id':'reference-1','phrase':'Finding','imageID':'local-image','imageIndex':0,'studyUID':'9.9.9','windowWidth':400,'windowCenter':40}
    assert c.put('/v1/studies/1.2.3.4/draft', json={'document':'Finding', 'evidence':[evidence], 'expected_revision':0}).status_code == 422
    evidence['studyUID'] = '1.2.3.4'
    assert c.put('/v1/studies/1.2.3.4/draft', json={'document':'No matching text', 'evidence':[evidence], 'expected_revision':0}).status_code == 422

def test_identity_cannot_be_cleared_by_explicit_empty_patient(tmp_path):
    c = client(tmp_path); c.post('/v1/studies', json=study())
    assert c.post('/v1/studies', json=study(patient_id='')).status_code == 409

def test_duplicate_evidence_ids_rejected_before_reaching_native_editor(tmp_path):
    c = client(tmp_path); c.post('/v1/studies', json=study())
    a = {'id':'same-id','phrase':'First','imageID':'local-image','imageIndex':0,'studyUID':'1.2.3.4','windowWidth':400,'windowCenter':40}
    b = a | {'phrase':'Second'}
    assert c.put('/v1/studies/1.2.3.4/draft', json={'document':'First. Second.', 'evidence':[a,b], 'expected_revision':0}).status_code == 422

def test_expired_worker_cannot_publish_after_another_worker_claims(tmp_path):
    import sqlite3, json
    c = client(tmp_path)
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=True)).json()
    first = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id':'first', 'expected_revision':item['revision']}).json()
    with sqlite3.connect(tmp_path / 'worklist.sqlite3') as conn:
        value = json.loads(conn.execute('SELECT payload FROM studies').fetchone()[0]); value['lease_expires'] = 0
        conn.execute('UPDATE studies SET payload=?', (json.dumps(value),))
    second = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id':'second', 'expected_revision':first['revision']}).json()
    draft = {'document':'Evaluation only', 'expected_revision':0}
    assert c.put('/v1/studies/1.2.3.4/draft', json=draft | {'claim_token':first['claim_token']}).status_code == 409
    assert c.put('/v1/studies/1.2.3.4/draft', json=draft).status_code == 409
    assert c.put('/v1/studies/1.2.3.4/draft', json=draft | {'claim_token':second['claim_token']}).status_code == 200
    assert 'claim_token' not in c.get('/v1/studies/1.2.3.4/draft').json()

def test_tag_limits_apply_to_patch_and_idempotency_preserves_field_presence(tmp_path):
    c = client(tmp_path); item = c.post('/v1/studies', json=study()).json()
    assert c.patch('/v1/studies/1.2.3.4', json={'tags':['x'*65], 'expected_revision':item['revision']}).status_code == 422
    headers={'Idempotency-Key':'partial-update'}
    assert c.post('/v1/studies', json={'study_uid':'1.2.3.4'}, headers=headers).status_code == 200
    assert c.post('/v1/studies', json={'study_uid':'1.2.3.4','patient_id':''}, headers=headers).status_code == 409

def test_pagination_and_status_filter_do_not_load_entire_worklist(tmp_path):
    c = client(tmp_path)
    for i in range(8): c.post('/v1/studies', json=study(study_uid=f'1.2.3.{i}', priority='urgent' if i==2 else 'routine'))
    page = c.get('/v1/studies?limit=3&offset=0').json()
    assert page['total']==8 and len(page['studies'])==3 and page['studies'][0]['priority']=='urgent'
    next_page = c.get('/v1/studies?limit=3&offset=3').json()
    assert not ({s['study_uid'] for s in page['studies']} & {s['study_uid'] for s in next_page['studies']})
    assert c.get('/v1/studies?status=draft').json()['total']==0


def test_lease_renewal_release_and_retry_are_owned_and_durable(tmp_path):
    c = client(tmp_path)
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=True)).json()
    claimed = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'automatic', 'expected_revision': item['revision']}).json()
    token = claimed['claim_token']
    assert c.post('/v1/studies/1.2.3.4/lease', json={'claim_token': 'wrong-token-' * 4}).status_code == 409
    renewed = c.post('/v1/studies/1.2.3.4/lease', json={'claim_token': token})
    assert renewed.status_code == 200
    assert renewed.json()['lease_expires'] >= claimed['lease_expires']
    assert c.request('DELETE', '/v1/studies/1.2.3.4/lease', json={'claim_token': 'wrong-token-' * 4}).status_code == 409
    released = c.request('DELETE', '/v1/studies/1.2.3.4/lease', json={'claim_token': token, 'failed': True})
    assert released.status_code == 200 and released.json()['status'] == 'attention'
    reopened = client(tmp_path)
    assert reopened.get('/v1/studies').json()['studies'][0]['status'] == 'attention'
    assert reopened.post('/v1/studies/1.2.3.4/lease', json={'claim_token': token}).status_code == 409
    queued = reopened.patch('/v1/studies/1.2.3.4', json={'status': 'queued', 'expected_revision': released.json()['revision']}).json()
    next_claim = reopened.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'retry', 'expected_revision': queued['revision']}).json()
    assert next_claim['claim_token'] != token
    assert reopened.put('/v1/studies/1.2.3.4/draft', json={'document': 'Fixture', 'expected_revision': 0, 'claim_token': token}).status_code == 409
    assert reopened.put('/v1/studies/1.2.3.4/draft', json={'document': 'Fixture', 'expected_revision': 0, 'claim_token': next_claim['claim_token']}).status_code == 200


def test_expired_lease_cannot_be_extended_and_completed_draft_cannot_be_released(tmp_path):
    import json
    import sqlite3
    c = client(tmp_path)
    item = c.post('/v1/studies', json=study(tags=['radagent-draft'], received_complete=True)).json()
    claimed = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'automatic', 'expected_revision': item['revision']}).json()
    with sqlite3.connect(tmp_path / 'worklist.sqlite3') as conn:
        value = json.loads(conn.execute('SELECT payload FROM studies').fetchone()[0]); value['lease_expires'] = 0
        conn.execute('UPDATE studies SET payload=?', (json.dumps(value),))
    assert c.post('/v1/studies/1.2.3.4/lease', json={'claim_token': claimed['claim_token']}).status_code == 409
    fresh = c.post('/v1/studies/1.2.3.4/claim', json={'worker_id': 'new', 'expected_revision': claimed['revision']}).json()
    assert c.put('/v1/studies/1.2.3.4/draft', json={'document': 'Fixture', 'expected_revision': 0, 'claim_token': fresh['claim_token']}).status_code == 200
    assert c.request('DELETE', '/v1/studies/1.2.3.4/lease', json={'claim_token': fresh['claim_token']}).status_code == 409
    assert c.get('/v1/studies').json()['studies'][0]['status'] == 'draft'
