import { init, RenderingEngine, Enums, cache, imageLoadPoolManager } from '@cornerstonejs/core';
import stackPrefetch from '@cornerstonejs/tools/utilities/stackPrefetch/stackPrefetch';
import { init as initDicom } from '@cornerstonejs/dicom-image-loader';

let initialized, engine, viewport, manifest, session, seriesUID, element, renderedRevision;
let transport, token, resizeObserver, lastState;
let renderQueue=Promise.resolve(),localSequence=0;
let requestedSession,studyGeneration=0,ready=false;
const waitPaint=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));

export async function initializeImaging(target,api,bearer){
  if(initialized)return initialized;
  transport=api;token=bearer;element=target;
  element.style.visibility='hidden';
  initialized=(async()=>{
    await init();
    imageLoadPoolManager.setMaxSimultaneousRequests(Enums.RequestType.Prefetch,2);
    initDicom({maxWebWorkers:2,beforeSend:(xhr,url)=>{
      if(new URL(url.replace(/^wadouri:/,''),location.href).origin!==location.origin)throw new Error('Only this local DICOM service is allowed.');
      xhr.setRequestHeader('Authorization','Bearer '+token);
    }});
    engine=new RenderingEngine('radagent');
    engine.enableElement({viewportId:'study',type:Enums.ViewportType.STACK,element,defaultOptions:{background:[0,0,0]}});
    viewport=engine.getViewport('study');
    resizeObserver=new ResizeObserver(()=>{if(element.clientWidth<64||element.clientHeight<64)return;engine.resize(true,false);if(lastState)present(lastState).catch(()=>{});});
    resizeObserver.observe(element);
  })();
  return initialized;
}

export function setImagingSession(id){
  if(requestedSession===id)return;
  requestedSession=id;studyGeneration++;lastState=null;manifest=null;session=null;
  ready=false;renderedRevision=null;
  if(element){element.style.visibility='hidden';if(seriesUID)stackPrefetch.disable(element);}
  seriesUID=null;
}

export function present(state,acknowledge=true){
  setImagingSession(state.session_id);
  const generation=studyGeneration;
  const sequence=++localSequence;
  const operation=async()=>{
    if(generation!==studyGeneration||(!acknowledge&&sequence!==localSequence))return {stale:true};
    try{return await renderState(state,acknowledge,generation);}
    catch(error){
      if(generation!==studyGeneration)return {stale:true};
      ready=false;element.style.visibility='hidden';throw error;
    }
  };
  renderQueue=renderQueue.catch(()=>{}).then(operation);
  return renderQueue;
}

async function renderState(state,acknowledge=true,generation){
  if(!viewport)return;
  const current=()=>generation===studyGeneration&&requestedSession===state.session_id;
  lastState=state;
  const view=state.follow?state.agent_view:state.user_view;
  if(session!==state.session_id){
    const nextManifest=await transport('dicom_manifest',{session_id:state.session_id});
    if(!current())return {stale:true};
    if(nextManifest.session_id!==state.session_id||nextManifest.study_uid!==state.study.studyUID)throw new Error('DICOM inventory does not match the selected study.');
    manifest=nextManifest;
    session=state.session_id;seriesUID=null;
  }
  if(manifest.upgrade_required)return {preview:true,message:manifest.message};
  if(element.clientWidth<64||element.clientHeight<64)return;
  const series=manifest.series.find(s=>s.uid===view.series_uid);
  if(!series)throw new Error('Selected series is unavailable in the original DICOM inventory.');
  const position=series.frames.findIndex(f=>f.index===view.image_index);
  if(position<0)throw new Error('Selected frame does not belong to this series.');
  const frame=series.frames[position];
  const imageIds=series.frames.map(f=>'wadouri:'+location.origin+'/dicom/'+state.session_id+'/'+f.key+'.dcm?frame='+(f.frame+1));
  if(seriesUID!==series.uid){
    ready=false;element.style.visibility='hidden';
    if(seriesUID)stackPrefetch.disable(element);
    await viewport.setStack(imageIds,position);
    if(!current())return {stale:true};
    seriesUID=series.uid;
    if(imageIds.length>1)stackPrefetch.enable(element);
  }else if(viewport.getCurrentImageIdIndex()!==position){await viewport.setImageIdIndex(position);}
  if(!current())return {stale:true};
  const imageId=viewport.getCurrentImageId(),data=cache.getImage(imageId)?.data;
  if(imageId!==imageIds[position]||data?.string('x0020000d')!==state.study.studyUID||data?.string('x0020000e')!==frame.series_instance_uid||data?.string('x00080018')!==frame.sop_instance_uid){
    throw new Error('Rendered DICOM identity does not match the selected study and image.');
  }
  presentation(view);viewport.render();
  if(!ready){await waitPaint();if(!current())return {stale:true};}
  ready=true;element.style.visibility='visible';
  if(acknowledge){
    await waitPaint();
    if(!current())return {stale:true};
    const canvas=viewport.getCanvas(),copy=document.createElement('canvas');
    // A capture is taken from the real Cornerstone viewport, not the Horos preview.
    copy.width=canvas.width;copy.height=canvas.height;
    const ctx=copy.getContext('2d');ctx.drawImage(canvas,0,0);
    if(view.region){const [x,y,w,h]=view.region;ctx.strokeStyle='#eeeeee';ctx.lineWidth=3;ctx.strokeRect(x*copy.width,y*copy.height,w*copy.width,h*copy.height);}
    const png=copy.toDataURL('image/png').split(',')[1];
    const identity={study_uid:state.study.studyUID,series_uid:series.uid,sop_instance_uid:frame.sop_instance_uid,image_index:frame.index,dicom_frame:frame.frame};
    await transport('rendered',{session_id:state.session_id,revision:state.revision,png,identity});renderedRevision=state.revision;
  }
}

function presentation(view){
  viewport.setProperties({voiRange:{lower:view.effective_center-view.effective_width/2,upper:view.effective_center+view.effective_width/2},invert:view.invert});
  viewport.setRotation(view.rotation);viewport.setZoom(view.zoom);
  viewport.setPan([view.pan_x*element.clientWidth,view.pan_y*element.clientHeight]);
}

export function previewPresentation(view){if(!isReady())return;presentation(view);viewport.render();}
export function isReady(){return !!viewport && ready && session===requestedSession;}

export function cacheStatus(){
  if(!isReady())return null;
  const ids=viewport.getImageIds();
  return {loaded:ids.filter(id=>cache.isLoaded(id)).length,total:ids.length};
}
