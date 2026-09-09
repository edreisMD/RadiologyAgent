"""Lazy, identity-checked original DICOM transport into Cornerstone."""
from __future__ import annotations
import base64
import fcntl
import hashlib
import io
import json
import os
import re
import tempfile
import pydicom
from .engine import Horos
from .storage import data_root, digest, write_json
from .workspace import Workspace


def original_series_uid(series):
    """Separate Horos's internal sorting key from DICOM Series Instance UID.

    Horos's SDK declares seriesDICOMUID separately. Older bridge inventories
    expose a sorting prefix and an optional image grouping suffix instead.
    """
    value=series.get('dicomUID') or series['uid']
    if re.fullmatch(r'[0-9]+(?:\.[0-9]+)+',value):return value
    match=re.fullmatch(r'[0-9]{8} ([0-9]+(?:\.[0-9]+)+)(?: +[0-9]+)?',value)
    if match:return match.group(1)
    raise ValueError('Horos series identity has an unrecognized format.')


def manifest(session_id):
    ws=Workspace();state=ws.read(session_id)
    folder=data_root()/'dicom'/session_id;folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (folder/'manifest.lock').open('a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        saved=folder/'manifest.json'
        previous=json.loads(saved.read_text()) if saved.exists() else {}
        if previous.get('protocol')==2:return previous
        study=state['detail']['study']
        if 'dicom-original' not in Horos().call('/health').get('capabilities',[]):
            return {'session_id':session_id,'study_uid':study['studyUID'],'series':[],'complete':False,
                    'source':'Horos preview','upgrade_required':True,
                    'message':'Horos preview · Restart Horos to enable the original-DICOM viewer.'}
        result=[]
        # Inventory only: never transfer an entire CT/MR before showing slice one.
        for series in state['detail']['series']:
            frames=[];series_uid=original_series_uid(series)
            for frame in series['frames']:
                sop=frame.get('sopInstanceUID')
                if not sop:raise ValueError('Native inventory has no SOP Instance UID.')
                key=digest([study['studyUID'],series_uid,sop])[:32]
                frames.append({'key':key,'index':frame['index'],'frame':frame['frame'],
                               'sop_instance_uid':sop,'rows':frame.get('height'),'columns':frame.get('width')})
            result.append({'uid':series['uid'],'name':series['name'],'modality':series['modality'],'frames':frames})
        value={'protocol':2,'session_id':session_id,'study_uid':study['studyUID'],'series':result,
               'source':'Original DICOM from Horos','complete':True,'delivery':'on-demand'}
        # Retain validated older cached files as aliases for already-open clients.
        if previous.get('complete') and previous.get('series'):write_json(folder/'legacy-manifest.json',previous)
        write_json(saved,value);return value


def file_path(session_id,key):
    ws=Workspace();ws.folder(session_id)
    if not re.fullmatch(r'[a-f0-9]{32}',key):raise ValueError('Invalid DICOM resource.')
    value=manifest(session_id)
    hit=next(((s,f) for s in value['series'] for f in s['frames'] if f['key']==key),None)
    folder=data_root()/'dicom'/session_id
    if hit is None:
        legacy=folder/'legacy-manifest.json'
        old=json.loads(legacy.read_text()) if legacy.exists() else {}
        old_hit=next((f for s in old.get('series',[]) for f in s['frames'] if f['key']==key),None)
        if old_hit and (folder/(key+'.dcm')).is_file():return folder/(key+'.dcm')
        raise ValueError('Instance is outside this study.')
    series,frame=hit
    with (folder/(key+'.lock')).open('a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        path=folder/(key+'.dcm')
        if path.is_file():return path
        state=ws.read(session_id);study=state['detail']['study']
        native_series=next(s for s in state['detail']['series'] if s['uid']==series['uid'])
        native_frame=next(f for f in native_series['frames'] if f['index']==frame['index'])
        response=Horos().call('/dicom',{'studyID':study['id'],'imageID':native_frame['id']})
        raw=base64.b64decode(response['dicom'],validate=True)
        ds=pydicom.dcmread(io.BytesIO(raw),stop_before_pixels=True)
        expected=(study['studyUID'],original_series_uid(native_series),frame['sop_instance_uid'])
        if (str(ds.StudyInstanceUID),str(ds.SeriesInstanceUID),str(ds.SOPInstanceUID))!=expected:
            raise ValueError('Original DICOM identity differs from Horos; load rejected.')
        count=int(ds.get('NumberOfFrames',1))
        if any(not 0<=f['frame']<count for f in series['frames'] if f['key']==key):
            raise ValueError('DICOM frame index is outside original instance.')
        fd,temporary=tempfile.mkstemp(dir=folder,prefix='.dicom-')
        try:
            with os.fdopen(fd,'wb') as out:out.write(raw)
            os.replace(temporary,path)
        finally:
            if os.path.exists(temporary):os.unlink(temporary)
        write_json(path.with_suffix('.json'),{'sha256':hashlib.sha256(raw).hexdigest(),'number_of_frames':count,
                    'rows':int(ds.Rows),'columns':int(ds.Columns),'transfer_syntax':str(ds.file_meta.TransferSyntaxUID)})
        return path
