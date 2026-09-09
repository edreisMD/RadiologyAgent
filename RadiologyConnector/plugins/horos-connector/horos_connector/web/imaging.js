import { init, RenderingEngine, Enums, cache, imageLoadPoolManager } from '@cornerstonejs/core';
import stackPrefetch from '@cornerstonejs/tools/utilities/stackPrefetch/stackPrefetch';
import { init as initDicom } from '@cornerstonejs/dicom-image-loader';

let initialized, engine, viewport, manifest, session, seriesUID, element, renderedRevision;
let transport, token, resizeObserver, lastState;
let renderQueue=Promise.resolve(),localSequence=0;
const waitPaint=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));

export async function initializeImaging(target,api,bearer){
  if(initialized)return initialized;
  transport=api;token=bearer;element=target;
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

export function present(state,acknowledge=true){
  const sequence=++localSequence;
  const operation=async()=>{
    if(!acknowledge&&sequence!==localSequence)return;
    return renderState(state,acknowledge);
  };
  renderQueue=renderQueue.catch(()=>{}).then(operation);
  return renderQueue;
}

async function renderState(state,acknowledge=true){
  if(!viewport)return;
  lastState=state;
  const view=state.follow?state.agent_view:state.user_view;
  if(session!==state.session_id){
    manifest=await transport('dicom_manifest',{session_id:state.session_id});
    session=state.session_id;seriesUID=null;
  }
  if(manifest.upgrade_required)return {preview:true,message:manifest.message};
  if(element.clientWidth<64||element.clientHeight<64)return;
  const series=manifest.series.find(s=>s.uid===view.series_uid);
  if(!series)throw new Error('Selected series is unavailable in the original DICOM inventory.');
  const position=series.frames.findIndex(f=>f.index===view.image_index);
  if(position<0)throw new Error('Selected frame does not belong to this series.');
  if(seriesUID!==series.uid){
    const imageIds=series.frames.map(f=>'wadouri:'+location.origin+'/dicom/'+session+'/'+f.key+'.dcm?frame='+(f.frame+1));
    if(seriesUID)stackPrefetch.disable(element);
    await viewport.setStack(imageIds,position);seriesUID=series.uid;
    if(imageIds.length>1)stackPrefetch.enable(element);
  }else if(viewport.getCurrentImageIdIndex()!==position){await viewport.setImageIdIndex(position);}
  presentation(view);viewport.render();
  if(acknowledge){
    await waitPaint();
    const canvas=viewport.getCanvas(),copy=document.createElement('canvas');
    // A capture is taken from the real Cornerstone viewport, not the Horos preview.
    copy.width=canvas.width;copy.height=canvas.height;
    const ctx=copy.getContext('2d');ctx.drawImage(canvas,0,0);
    if(view.region){const [x,y,w,h]=view.region;ctx.strokeStyle='#eeeeee';ctx.lineWidth=3;ctx.strokeRect(x*copy.width,y*copy.height,w*copy.width,h*copy.height);}
    const png=copy.toDataURL('image/png').split(',')[1];
    await transport('rendered',{session_id:session,revision:state.revision,png});renderedRevision=state.revision;
  }
}

function presentation(view){
  viewport.setProperties({voiRange:{lower:view.effective_center-view.effective_width/2,upper:view.effective_center+view.effective_width/2},invert:view.invert});
  viewport.setRotation(view.rotation);viewport.setZoom(view.zoom);
  viewport.setPan([view.pan_x*element.clientWidth,view.pan_y*element.clientHeight]);
}

export function previewPresentation(view){if(!viewport)return;presentation(view);viewport.render();}
export function isReady(){return !!viewport && !!seriesUID;}

export function cacheStatus(){
  if(!viewport||!seriesUID)return null;
  const ids=viewport.getImageIds();
  return {loaded:ids.filter(id=>cache.isLoaded(id)).length,total:ids.length};
}
