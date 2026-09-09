"""Forward labelled StableStudy events to Radiology Agent; optionally route DICOM to Horos."""
import json
import os
import time
from pathlib import Path
from urllib.parse import urlparse
import httpx


def validate_url(value):
    parsed = urlparse(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Keep credentials separate from service URLs')
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')):
        raise ValueError('Service URLs require HTTPS or loopback HTTP')
    return value.rstrip('/')


def payload_for(study, patient):
    tags = study['MainDicomTags']
    person = patient['MainDicomTags']
    return {
        'study_uid': tags['StudyInstanceUID'],
        'patient_id': person.get('PatientID', ''),
        'patient_name': person.get('PatientName', '').replace('^', ' '),
        'accession': tags.get('AccessionNumber', ''),
        'description': tags.get('StudyDescription', ''),
        'modality': tags.get('ModalitiesInStudy', '').split('\\')[0],
        'tags': study.get('Labels', []),
        'received_complete': True,
    }


def main():
    orthanc_url = validate_url(os.environ['ORTHANC_URL'])
    backend_url = validate_url(os.environ.get('RADAGENT_BACKEND_URL', 'http://127.0.0.1:8043'))
    token = os.environ['RADAGENT_BACKEND_TOKEN']
    auth = (os.environ['ORTHANC_USER'], os.environ['ORTHANC_PASSWORD']) if os.environ.get('ORTHANC_USER') else None
    state = Path(os.environ.get('RADAGENT_BRIDGE_STATE', './backend-data/orthanc-cursor.json'))
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    cursor = json.loads(state.read_text())['since'] if state.exists() else 0
    with httpx.Client(base_url=orthanc_url, auth=auth, timeout=120, follow_redirects=False) as orthanc, httpx.Client(base_url=backend_url, headers={'Authorization': f'Bearer {token}'}, timeout=30, follow_redirects=False) as backend:
        while True:
            response = orthanc.get('/changes', params={'since': cursor, 'limit': 100})
            response.raise_for_status()
            batch = response.json()
            for event in batch['Changes']:
                if event['ChangeType'] == 'StableStudy':
                    response = orthanc.get('/studies/' + event['ID']); response.raise_for_status(); study = response.json()
                    if 'radagent-draft' in study.get('Labels', []):
                        response = orthanc.get('/patients/' + study['ParentPatient']); response.raise_for_status(); patient = response.json()
                        if modality := os.environ.get('ORTHANC_HOROS_MODALITY'):
                            response = orthanc.post('/modalities/' + modality + '/store', json={'Resources': [event['ID']]})
                            response.raise_for_status()
                        response = backend.post('/v1/studies', json=payload_for(study, patient), headers={'Idempotency-Key': 'orthanc-' + str(event['Seq'])})
                        response.raise_for_status()
                cursor = event['Seq']
                temporary = state.with_suffix('.tmp')
                temporary.write_text(json.dumps({'since': cursor})); temporary.chmod(0o600); temporary.replace(state)
            if batch['Done']:
                time.sleep(5)

if __name__ == '__main__':
    main()
