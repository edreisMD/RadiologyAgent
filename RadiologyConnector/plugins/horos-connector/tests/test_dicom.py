import base64
import copy
import io
import json
import time
import pytest
from PIL import Image
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, CTImageStorage
from test_connector import detail, FakeEngine, isolated
from horos_connector.workspace import Workspace, view_identity
from horos_connector import dicom
from horos_connector.storage import write_json


def fixture_bytes(study='1.2.3', series='1.2.3.1', sop='1.2.3.10', count=3):
    meta=FileMetaDataset();meta.TransferSyntaxUID=ExplicitVRLittleEndian
    meta.MediaStorageSOPClassUID=CTImageStorage;meta.MediaStorageSOPInstanceUID=sop
    ds=FileDataset(None,{},file_meta=meta,preamble=b'\0'*128)
    ds.StudyInstanceUID=study;ds.SeriesInstanceUID=series;ds.SOPInstanceUID=sop
    ds.SOPClassUID=CTImageStorage;ds.Rows=64;ds.Columns=64
    ds.NumberOfFrames=count;ds.SamplesPerPixel=1;ds.PhotometricInterpretation='MONOCHROME2'
    ds.BitsAllocated=16;ds.BitsStored=12;ds.HighBit=11;ds.PixelRepresentation=0
    ds.PixelData=b'\0\0'*(64*64*count)
    output=io.BytesIO();ds.save_as(output,enforce_file_format=True);return output.getvalue()


def setup_study(monkeypatch,raw=None):
    d=detail()
    d['series'][0]['uid']='00000001 1.2.3.1    1'
    for i,f in enumerate(d['series'][0]['frames']):f.update(sopInstanceUID='1.2.3.10',frame=i)
    state=Workspace(FakeEngine()).open(detail=d);calls=[]
    class Native:
        def call(self,route,body=None):
            if route=='/health':return {'capabilities':['dicom-original']}
            assert route=='/dicom'
            assert body=={'studyID':'study','imageID':'frame-0'}
            calls.append(body);return {'dicom':base64.b64encode(raw or fixture_bytes()).decode()}
    monkeypatch.setattr(dicom,'Horos',Native)
    return state['session_id'],calls


def test_original_multiframe_preserves_bytes_and_exact_frame_mapping(isolated,monkeypatch):
    sid,calls=setup_study(monkeypatch)
    value=dicom.manifest(sid);frames=value['series'][0]['frames']
    assert value['complete'] and value['delivery']=='on-demand' and len(calls)==0
    assert [f['frame'] for f in frames]==[0,1,2]
    assert [f['index'] for f in frames]==[0,1,2]
    assert len({f['key'] for f in frames})==1
    assert dicom.file_path(sid,frames[0]['key']).read_bytes()==fixture_bytes()
    assert len(calls)==1
    with pytest.raises(ValueError):dicom.file_path(sid,'a'*32)


@pytest.mark.parametrize('field',['study','series','sop'])
def test_original_identity_mismatch_rejected_before_caching(isolated,monkeypatch,field):
    sid,_=setup_study(monkeypatch,fixture_bytes(**{field:'9.8.7'}))
    m=dicom.manifest(sid)
    with pytest.raises(ValueError,match='identity differs'):dicom.file_path(sid,m['series'][0]['frames'][0]['key'])
    assert not list((isolated/'dicom'/sid).glob('*.dcm'))


def test_horos_composite_uid_is_strict_not_a_substring_match():
    assert dicom.original_series_uid({'uid':'00000001 1.2.3.4    1'})=='1.2.3.4'
    assert dicom.original_series_uid({'uid':'00000003 1.2.3.4'})=='1.2.3.4'
    assert dicom.original_series_uid({'uid':'legacy','dicomUID':'1.2.3.4'})=='1.2.3.4'
    for value in ['junk 1.2.3.4','00000001 1.2.3.4bad    1','1.2.3.4 arbitrary']:
        with pytest.raises(ValueError):dicom.original_series_uid({'uid':value})


def test_older_bridge_is_explicit_preview_without_any_dicom_file_read(isolated,monkeypatch):
    sid=Workspace(FakeEngine()).open(detail=detail())['session_id']
    class Old:
        def call(self,route,body=None):
            assert route=='/health'
            return {'capabilities':[]}
    monkeypatch.setattr(dicom,'Horos',Old)
    value=dicom.manifest(sid)
    assert value['upgrade_required'] and value['source']=='Horos preview' and not value['complete']
    assert not list((isolated/'dicom'/sid).glob('*.dcm'))


def test_browser_capture_keeps_renderer_identity_and_rejects_stale_revision(isolated,monkeypatch):
    from horos_connector import server, workspace_service
    ws=Workspace(FakeEngine());sid=ws.open(detail=detail())['session_id']
    out=io.BytesIO();Image.new('RGB',(128,128),(120,80,40)).save(out,format='PNG')
    png=base64.b64encode(out.getvalue()).decode()
    assert workspace_service.ui_call('rendered',dict(session_id=sid,revision=0,png=png))=={'accepted':False}
    identity=view_identity(ws.read(sid))
    for bad in [None,dict(identity,study_uid='9.8.7'),dict(identity,image_index=1),dict(identity,sop_instance_uid='9.8.7')]:
        with pytest.raises(ValueError,match='Viewport identity'):
            workspace_service.ui_call('rendered',dict(session_id=sid,revision=1,png=png,identity=bad))
    for renderer in ['Cornerstone3D','Horos preview']:
        workspace_service.ui_call('rendered',dict(session_id=sid,revision=1,png=png,renderer=renderer,identity=identity))
        result=server.current_view(sid)
        assert renderer in result.content[0].text
        assert base64.b64decode(result.content[1].data)==out.getvalue()
    ws.action(sid,{'zoom':2})
    with pytest.raises(ValueError,match='No current browser capture'):server.current_view(sid)


def localizer_study(monkeypatch,wrong_study=False):
    d=detail(count=2);d['series'][0]['uid']='LOCALIZER'
    # A Horos group is allowed to contain more than one original DICOM series.
    d['series'][0]['dicomUID']='1.2.3.1'
    state=Workspace(FakeEngine()).open(detail=d);calls=[]
    class Native:
        def call(self,route,body=None):
            if route=='/health':return {'capabilities':['dicom-original']}
            assert route=='/dicom' and body['studyID']=='study'
            i=int(body['imageID'].split('-')[-1]);calls.append(i)
            raw=fixture_bytes(study='9.8.7' if wrong_study else '1.2.3',series=f'1.2.3.{i+1}',sop=f'1.2.3.{i+10}',count=1)
            return {'dicom':base64.b64encode(raw).decode()}
    monkeypatch.setattr(dicom,'Horos',Native)
    return state['session_id'],calls


def test_localizer_group_resolves_each_original_series_and_keeps_exact_images(isolated,monkeypatch):
    sid,calls=localizer_study(monkeypatch)
    value=dicom.manifest(sid)
    assert value['protocol']==3 and value['series'][0]['uid']=='LOCALIZER'
    frames=value['series'][0]['frames']
    assert [f['series_instance_uid'] for f in frames]==['1.2.3.1','1.2.3.2']
    assert len(calls)==2
    for i,f in enumerate(frames):
        assert dicom.file_path(sid,f['key']).read_bytes()==fixture_bytes(series=f'1.2.3.{i+1}',sop=f'1.2.3.{i+10}',count=1)
    assert dicom.manifest(sid)==value and len(calls)==4


def test_localizer_from_another_patient_is_rejected(isolated,monkeypatch):
    sid,_=localizer_study(monkeypatch,wrong_study=True)
    with pytest.raises(ValueError,match='identity differs'):dicom.manifest(sid)
    assert not list((isolated/'dicom'/sid).glob('*.dcm'))
    assert not (isolated/'dicom'/sid/'manifest.json').exists()


def test_protocol_two_inventory_upgrades_without_eager_stack_download(isolated,monkeypatch):
    sid,calls=setup_study(monkeypatch)
    value=dicom.manifest(sid)
    value['protocol']=2
    for frame in value['series'][0]['frames']:frame.pop('series_instance_uid')
    write_json(isolated/'dicom'/sid/'manifest.json',value)
    upgraded=dicom.manifest(sid)
    assert upgraded['protocol']==3 and not calls
    assert all(f['series_instance_uid']=='1.2.3.1' for f in upgraded['series'][0]['frames'])
