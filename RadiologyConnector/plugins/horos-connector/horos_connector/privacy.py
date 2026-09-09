"""Demo display aliases. This does not claim to de-identify original DICOM."""
from __future__ import annotations
import fcntl
import json
from .storage import config, data_root, write_json


def demo_mode():return bool(config().get('demo_display_aliases',False))


def public_study(study):
    if not demo_mode():return dict(study)
    root=data_root();file=root/'demo-aliases.json'
    with (root/'demo-aliases.lock').open('a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        aliases=json.loads(file.read_text()) if file.exists() else {}
        uid=study['studyUID']
        if uid not in aliases:
            aliases[uid]=len(aliases)+1;write_json(file,aliases)
        number=aliases[uid]
    modality=study.get('modality','')
    title={'CR':'Radiographs','DX':'Radiographs','CT':'CT examination','MR':'MRI examination','US':'Ultrasound examination','MG':'Mammography'}.get(modality,'Imaging examination')
    return dict(study,patientName=f'Patient {number:03}',patientID=f'DEMO-{number:03}',title=title,date=None,accession=None)


def series_name(series,index):
    if demo_mode():return f'{series.get("modality") or "Imaging"} series {index+1:02}'
    return series['name'] if series.get('name') and series['name'].lower()!='unnamed' else f'Series {index+1}'
