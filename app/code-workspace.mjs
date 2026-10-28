import {extractCodeFiles, buildPreviewHtml, makeCodeZip} from './code-files.mjs';

function element(tag, className, text) {
  const node=document.createElement(tag);
  if (className) node.className=className;
  if (text !== undefined) node.textContent=text;
  return node;
}
function download(blob, filename) {
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url;a.download=filename;a.style.display='none';
  document.body.append(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),30000);
}
export function renderCodeWorkspace(files) {
  if (!files?.length) return null;
  const container=element('section','code-workspace');
  container.setAttribute('aria-label','TUZE жасаған код файлдары');
  const header=element('div','workspace-header');
  const title=element('div','workspace-title');
  title.append(element('span','workspace-icon','⌘'),element('strong','',`Файлдар · ${files.length}`));
  const all=element('button','workspace-zip','↓ ZIP');all.type='button';
  all.title='Барлық код файлын бір ZIP архивімен жүктеу';
  all.addEventListener('click',()=>{try{download(makeCodeZip(files),'TUZE-project.zip');}catch(e){alert('ZIP қатесі: '+e.message);}});
  header.append(title,all);container.append(header);
  const fileBar=element('div','workspace-file-tabs');fileBar.setAttribute('role','tablist');
  container.append(fileBar);
  const controls=element('div','workspace-controls');
  const viewButton=element('button','workspace-mode','◫ Нәтиже');viewButton.type='button';
  const codeButton=element('button','workspace-mode','⌘ Код');codeButton.type='button';
  const saveFile=element('button','workspace-file-download','↓ Файлды жүктеу');saveFile.type='button';
  controls.append(viewButton,codeButton,saveFile);container.append(controls);
  const display=element('div','workspace-display');container.append(display);
  const canPreview=files.some(f=>f.language==='html');
  let selected = canPreview ? files.findIndex(f=>f.language==='html' && /(?:^|\/)index\.html$/i.test(f.name)) : 0;
  if (selected < 0) selected=files.findIndex(f=>f.language==='html');
  let mode=canPreview?'preview':'code';
  let lastFrame=null;
  function show() {
    fileBar.replaceChildren();
    files.forEach((file,index)=>{
      const tab=element('button','workspace-tab'+(index===selected?' selected':''),file.name);
      tab.type='button';tab.setAttribute('role','tab');tab.setAttribute('aria-selected',String(index===selected));
      tab.addEventListener('click',()=>{selected=index;mode=file.language==='html'?'preview':'code';show();});
      fileBar.append(tab);
    });
    viewButton.hidden=!canPreview;
    viewButton.classList.toggle('selected',mode==='preview');
    codeButton.classList.toggle('selected',mode==='code');
    display.replaceChildren(); lastFrame=null;
    if(mode==='preview' && canPreview){
      const frame=document.createElement('iframe');
      frame.className='workspace-frame';frame.title='Кодтың тірі нәтижесі';frame.loading='lazy';
      frame.setAttribute('sandbox','allow-scripts');
      frame.setAttribute('referrerpolicy','no-referrer');
      frame.src='/preview-frame.html';
      const selectedFile=files[selected].language==='html'?files[selected].name:'';
      const html=buildPreviewHtml(files,selectedFile);
      frame.addEventListener('load',()=>{
        // The preview is sandboxed with a unique opaque origin. It cannot read TUZE chats or GitHub keys.
        if (frame !== lastFrame) return;
        frame.contentWindow?.postMessage({kind:'tuze-code-preview-v1',html},'*');
      });
      const info=element('div','workspace-preview-info','Тірі HTML/CSS/JS көрінісі · Бөлек қауіпсіз аймақта іске қосылады');
      display.append(info,frame);lastFrame=frame;
    } else {
      const pre=element('pre','workspace-source');
      const code=element('code','',files[selected].content);
      pre.append(code);display.append(pre);
      if(!canPreview) display.append(element('div','workspace-hint','Бұл файлдың орындалуын браузерде көрсету мүмкін емес. Кодты қарап, жүктей аласың.'));
    }
  }
  viewButton.addEventListener('click',()=>{mode='preview';show();});
  codeButton.addEventListener('click',()=>{mode='code';show();});
  saveFile.addEventListener('click',()=>download(new Blob([files[selected].content],{type:'text/plain;charset=utf-8'}),files[selected].name.split('/').pop()));
  show();
  return container;
}
export {extractCodeFiles};
