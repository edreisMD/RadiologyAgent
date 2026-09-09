import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const source=await readFile(new URL('../imaging.js',import.meta.url),'utf8');
const fixture=(session,study)=>({session_id:session,study:{studyUID:study},revision:1,follow:true,
  agent_view:{series_uid:study+'.1',image_index:0,effective_center:40,effective_width:400,rotation:0,zoom:1,pan_x:0,pan_y:0}});
const inventory=state=>({session_id:state.session_id,study_uid:state.study.studyUID,series:[{
  uid:state.agent_view.series_uid,frames:[{key:'instance',index:0,frame:0,
    series_instance_uid:state.study.studyUID+'.1',sop_instance_uid:state.study.studyUID+'.10'}]}]});
const a=fixture('a','1.2.3'),b=fixture('b','1.2.4');
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};

async function harness(manifest=async id=>inventory(id==='a'?a:b)){
  const canvas={width:400,height:400,getContext:()=>({drawImage(){},strokeRect(){}}),toDataURL:()=> 'data:image/png;base64,TEST'};
  const element={clientWidth:400,clientHeight:400,style:{}};
  const captures=[],images=new Map();let ids=[],position=0;
  const viewport={
    async setStack(next,index){ids=next;position=index;
      for(const id of ids){const sid=new URL(id.slice(8)).pathname.split('/')[2],study=sid==='a'?'1.2.3':'1.2.4';
        images.set(id,{data:{string:tag=>({'x0020000d':study,'x0020000e':study+'.1','x00080018':study+'.10'})[tag]}});}
    },
    async setImageIdIndex(index){position=index;},getCurrentImageIdIndex:()=>position,
    getCurrentImageId:()=>ids[position],getImageIds:()=>ids,getCanvas:()=>canvas,
    setProperties(){},setRotation(){},setZoom(){},setPan(){},render(){}
  };
  const context=vm.createContext({URL,location:{origin:'http://127.0.0.1:1234'},
    document:{createElement:()=>canvas},requestAnimationFrame:fn=>setTimeout(fn,0),ResizeObserver:class{observe(){}},console});
  const modules={
    '@cornerstonejs/core':{init:async()=>{},RenderingEngine:class{enableElement(){} getViewport(){return viewport;} resize(){}},
      Enums:{RequestType:{Prefetch:'prefetch'},ViewportType:{STACK:'stack'}},cache:{getImage:id=>images.get(id),isLoaded:id=>images.has(id)},imageLoadPoolManager:{setMaxSimultaneousRequests(){}}},
    '@cornerstonejs/tools/utilities/stackPrefetch/stackPrefetch':{default:{enable(){},disable(){}}},
    '@cornerstonejs/dicom-image-loader':{init(){}}
  };
  const module=new vm.SourceTextModule(source,{context});
  await module.link(specifier=>new vm.SyntheticModule(Object.keys(modules[specifier]),function(){
    for(const [key,value] of Object.entries(modules[specifier]))this.setExport(key,value);
  },{context}));
  await module.evaluate();
  const imaging=module.namespace;
  await imaging.initializeImaging(element,async(method,args)=>{
    if(method==='dicom_manifest')return manifest(args.session_id);
    captures.push(args);return {accepted:true};
  },'test');
  return {imaging,element,captures,images,viewport};
}

test('failed study load immediately hides previous patient and never acknowledges it',async()=>{
  const h=await harness(async id=>{if(id==='b')throw new Error('unrecognized localizer');return inventory(a);});
  await h.imaging.present(a);assert.equal(h.element.style.visibility,'visible');
  const pending=h.imaging.present(b);
  assert.equal(h.element.style.visibility,'hidden');assert.equal(h.imaging.isReady(),false);
  await assert.rejects(pending,/unrecognized localizer/);
  assert.equal(h.element.style.visibility,'hidden');assert.equal(h.imaging.cacheStatus(),null);
  assert.deepEqual(h.captures.map(c=>c.session_id),['a']);
});

test('late completion from prior study cannot display or acknowledge pixels under new study',async()=>{
  const entered=deferred(),wait=deferred();
  const h=await harness(async id=>{if(id==='a'){entered.resolve();await wait.promise;}return inventory(id==='a'?a:b);});
  const first=h.imaging.present(a);await entered.promise;
  const second=h.imaging.present(b);wait.resolve();await first;await second;
  assert.deepEqual(h.captures.map(c=>c.session_id),['b']);
  assert.equal(h.captures[0].identity.study_uid,'1.2.4');
  assert.equal(h.element.style.visibility,'visible');assert.equal(h.imaging.isReady(),true);
});

test('wrong DICOM pixels from cache are rejected despite correct requested URL',async()=>{
  const h=await harness();await h.imaging.present(a);
  h.images.get(h.viewport.getCurrentImageId()).data.string=()=> '1.2.4';
  await assert.rejects(h.imaging.present({...a,revision:2}),/Rendered DICOM identity/);
  assert.equal(h.element.style.visibility,'hidden');assert.equal(h.captures.length,1);
});

test('worklist navigation invalidates in-flight rendering',async()=>{
  const entered=deferred(),wait=deferred();
  const h=await harness(async()=>{entered.resolve();await wait.promise;return inventory(a);});
  const first=h.imaging.present(a);await entered.promise;h.imaging.setImagingSession(null);wait.resolve();await first;
  assert.equal(h.element.style.visibility,'hidden');assert.equal(h.imaging.isReady(),false);assert.equal(h.captures.length,0);
});
