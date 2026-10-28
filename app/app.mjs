import { ChatStore, localClient, githubClient } from './store.mjs';
import { extractCodeFiles, renderCodeWorkspace } from './code-workspace.mjs';

const $ = id => document.getElementById(id);
const local = localClient();
let store = null;
let active = null;
let busy = false;
let proposal = null;
let pendingImage = null;
let legacyMaster = null;
let currentToken = null;
let sessionCheck = false;
let correctEnabled = true; // Show automatic suggestions after typing pauses; allow turning them off.
let loginPoll = null;
let tuzeTimer = null;
let tuzeRevision = 0;
let tuzeInFlight = false;
let proposalOriginal = null;
let messageReview = null;
let messageRevision = 0;
let logoRevision = 0;
let logoOriginal = null;
let logoQuestions = [];
let logoLoading = false;

function message(text, error = false) {
  $('notice').textContent = text;
  $('notice').classList.toggle('error', error);
  $('notice').hidden = !text;
}
function syncStatus(text) { $('sync-status').textContent = text; }
function setBusy(value) {
  busy = value;
  for (const id of ['new-chat','new-chat-top','send']) $(id).disabled = value;
  $('draft').disabled = value;
  $('photo-input').disabled = value;
  $('remove-photo').disabled = value;
}
function assertUnlocked() {
  if (!store) throw new Error('Алдымен GitHub аккаунтыңмен кір.');
}

async function api(path, body) {
  const response = await fetch(path, body === undefined ? {cache:'no-store'} : {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body), cache:'no-store',
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

async function renderList() {
  const names = store ? await local.list() : [];
  const selected = $('search').value.trim().toLocaleLowerCase();
  const items = [];
  for (const filename of names) {
    let title = filename;
    try { title = (await store.open(filename)).title || filename; }
    catch { title = filename + ' · ескі чат'; }
    items.push({filename, title});
  }
  const results = items.filter(x => !selected || (x.title + ' ' + x.filename).toLocaleLowerCase().includes(selected)).reverse();
  $('chat-list').replaceChildren();
  for (const {filename, title} of results) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'chat-item' + (active?.filename === filename ? ' current' : '');
    button.title = title;
    button.textContent = title;
    button.addEventListener('click', () => run(async () => {
      assertUnlocked(); active = await store.open(filename);
      renderChat(); await renderList();
      if (window.innerWidth <= 700) setCollapsed(true);
    }));
    $('chat-list').append(button);
  }
  if (!results.length) {
    const empty = document.createElement('div'); empty.className = 'empty-list';
    empty.textContent = selected ? 'Чат табылмады' : 'Әзірге чат жоқ';
    $('chat-list').append(empty);
  }
}
function richContent(text) {
  const root = document.createElement('div'); root.className = 'msg-body';
  const parts = text.split(/```/g);
  parts.forEach((part, i) => {
    if (i % 2) {
      const pre = document.createElement('pre'), code = document.createElement('code');
      code.textContent = part.replace(/^[a-zA-Z+#.-]+\n/, '');
      pre.append(code); root.append(pre);
    } else if (part) {
      const span = document.createElement('span'); span.textContent = part; root.append(span);
    }
  });
  return root;
}
function renderChat() {
  if (logoOriginal !== null && active?.id !== window.__logoChatId) closeLogo();
  if (messageReview && messageReview.chatId !== active?.id) { messageRevision++; messageReview=null; }
  $('chat-title').textContent = active?.title || 'Жаңа чат';
  $('chat-file').textContent = active?.filename || '';
  const list = $('messages'); list.replaceChildren();
  if (!active || active.messages.length === 0) {
    const intro = document.createElement('div'); intro.className = 'empty-state';
    intro.innerHTML = '<div class="hero-mark">✳</div><h1>Бүгін неден бастаймыз?</h1><p>gpt-oss:20b · жергілікті TUZE</p>';
    list.append(intro); return;
  }
  for (const item of active.messages) {
    const entry = document.createElement('article'); entry.className = 'message ' + item.role;
    if (item.role === 'assistant') {
      const head = document.createElement('div'); head.className = 'assistant-head';
      const logo = document.createElement('span'); logo.className = 'assistant-symbol'; logo.textContent = '✳';
      const title = document.createElement('span'); title.textContent = 'TUZE';
      head.append(logo, title); entry.append(head);
    }
    // Every assistant code response becomes persistent, downloadable files with an inline preview.
    // The files are reconstructed from the saved chat message, including after a GitHub sync.
    const codeArtifact = item.role === 'assistant' ? extractCodeFiles(item.content) : null;
    if (codeArtifact?.files.length) {
      if (codeArtifact.prose) entry.append(richContent(codeArtifact.prose));
      entry.append(renderCodeWorkspace(codeArtifact.files));
    } else {
      entry.append(richContent(item.content));
    }
    if (item.image) {
      const photo = document.createElement('img');
      photo.src = `data:image/jpeg;base64,${item.image.data}`;
      photo.alt = 'Тіркелген фото'; photo.className = 'chat-photo'; entry.append(photo);
    }
    const actions = document.createElement('div'); actions.className = 'msg-actions';
    const copy = document.createElement('button'); copy.type = 'button'; copy.className = 'copy-message';
    copy.textContent = '⧉ Көшіру'; copy.title = 'Мәтінді көшіру';
    copy.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(item.content); copy.textContent = '✓ Көшірілді'; }
      catch { message('Мәтінді көшіру мүмкін болмады.', true); }
    });
    actions.append(copy);
    const fix=document.createElement('button');
    fix.type='button';fix.className='fix-message';fix.textContent='✦ Түзету';
    fix.title='Осы хабарламаның қатесін TUZE арқылы түзету';
    fix.disabled=!item.content?.trim();
    fix.addEventListener('click',()=>{void correctMessage(item.id);});
    actions.append(fix);entry.append(actions);
    if(messageReview?.chatId===active.id && messageReview?.messageId===item.id){
      entry.append(renderMessageReview(messageReview));
    }
    list.append(entry);
  }
  list.scrollTop = list.scrollHeight;
}
function renderMessageReview(review) {
  const panel=document.createElement('section'); panel.className='msg-review';
  const header=document.createElement('div'); header.className='review-title';
  const title=document.createElement('span'); title.textContent='✦ TUZE · Хабарламаны түзету';
  const close=document.createElement('button'); close.type='button'; close.textContent='✕'; close.title='Жабу';
  close.addEventListener('click',()=>{ messageReview=null; messageRevision++; renderChat(); });
  header.append(title,close);panel.append(header);
  if (review.loading) { const line=document.createElement('p'); line.textContent='gpt-oss:20b мәтінді тексеріп жатыр…';panel.append(line); return panel; }
  if (review.error) { const error=document.createElement('p'); error.className='review-error';error.textContent=review.error;panel.append(error);
    const retry=document.createElement('button');retry.type='button';retry.textContent='Қайта тексеру';retry.className='fix-message';
    retry.addEventListener('click',()=>{void correctMessage(review.messageId);});panel.append(retry);return panel; }
  const diff=document.createElement('div');drawDifference(review.original,review.proposed,diff);panel.append(diff);
  const note=document.createElement('p');note.className='review-note';note.textContent=review.warnings?.join(' ') || (review.original===review.proposed ? 'Өзгеріс қажет емес.' : 'Өзгерісті қарап, қолдануыңа болады.');panel.append(note);
  const buttons=document.createElement('div');buttons.className='review-controls';
  const apply=document.createElement('button');apply.type='button';apply.className='primary';apply.textContent='Өзгерісті қолдану';
  apply.disabled=review.proposed===review.original;
  apply.addEventListener('click',()=>run(async()=>{
    assertUnlocked();
    if (active?.id !== review.chatId) throw new Error('Чат өзгерген.');
    active=await store.editMessage(active.filename,review.messageId,review.original,review.proposed);
    messageReview=null;messageRevision++;renderChat();await renderList();await syncCurrent();
    message('Хабарлама түзетілді және сақталды.');
  }));
  const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Бас тарту';
  cancel.addEventListener('click',()=>{messageReview=null;messageRevision++;renderChat();});
  buttons.append(apply,cancel);panel.append(buttons);return panel;
}
async function correctMessage(messageId) {
  if (busy || !store || !active) return;
  const found=active.messages.find(m=>m.id===messageId);
  if (!found || !found.content.trim()) return;
  if (found.content.length>3600) {message('Түзету 3600 таңбаға дейін жұмыс істейді.',true);return;}
  const current=++messageRevision;
  const review={chatId:active.id,messageId,original:found.content,proposed:null,warnings:[],loading:true,error:null};
  messageReview=review;renderChat();
  try {
    const job=await api('/api/tuze/start',{text:found.content,mode:'correct'});
    if (!/^[a-f0-9]{32}$/.test(job.job_id||'')) throw new Error('Түзету тапсырмасы ашылмады.');
    let data=null;
    for (let attempt=0;attempt<900;attempt++) {
      if(current!==messageRevision || messageReview!==review) return;
      await new Promise(resolve=>setTimeout(resolve,1000));
      data=await api(`/api/tuze/result/${job.job_id}`);
      if(data.done) break;
    }
    if (!data?.done) throw new Error('gpt-oss:20b жауап бермеді. Ollama қызметін тексер.');
    if (data.error) throw new Error(data.error);
    if(!data.result || typeof (data.result.suggested_text || data.result.corrected_text) !== 'string') throw new Error('Модель түзету мәтінін қайтармады.');
    if(current!==messageRevision || messageReview!==review) return;
    review.proposed=data.result.suggested_text || data.result.corrected_text;
    review.warnings=data.result.warnings || [];
    review.loading=false;renderChat();
  } catch(error) {
    if(current!==messageRevision || messageReview!==review) return;
    review.error=error.message || 'Түзету сәтсіз аяқталды.';review.loading=false;renderChat();
  }
}

function showThinking() {
  const old = $('thinking'); if (old) old.remove();
  if ($('messages').querySelector('.empty-state')) return;
  const item = document.createElement('div'); item.id = 'thinking'; item.className = 'typing';
  const status = document.createElement('div'); status.id = 'thinking-status';
  status.textContent = 'gpt-oss:20b жедел жадқа дайындалуда… (RAM көлеміне байланысты ұзақ болуы мүмкін)';
  const output = document.createElement('pre'); output.id = 'thinking-output';
  output.hidden = true;
  item.append(status, output); $('messages').append(item);
  $('messages').scrollTop = $('messages').scrollHeight;
}

function updateThinking(stage, partial = '') {
  const status = $('thinking-status'), output = $('thinking-output');
  if (!status || !output) return;
  status.textContent = stage === 'generating'
    ? 'TUZE жауап жазып жатыр…'
    : stage === 'loading' ? 'Ollama gpt-oss:20b моделін жедел жадқа дайындауда…'
    : 'gpt-oss:20b сұрауы басталды…';
  if (partial) {
    output.hidden = false;
    output.textContent = partial;
    $('messages').scrollTop = $('messages').scrollHeight;
  }
}

function drawDifference(original, corrected, target = $('difference')) {
  const box = target; box.replaceChildren();
  let prefix = 0;
  while (prefix < Math.min(original.length, corrected.length) && original[prefix] === corrected[prefix]) prefix++;
  let left = original.length, right = corrected.length;
  while (left > prefix && right > prefix && original[left - 1] === corrected[right - 1]) { left--; right--; }
  for (const [label, text, end, color] of [
    ['Алдыңғы нұсқа', original, left, 'old'], ['Кейінгі нұсқа', corrected, right, 'new'],
  ]) {
    const row = document.createElement('div'); row.className = 'diff-row';
    const title = document.createElement('b'); title.textContent = label;
    const content = document.createElement('p');
    content.append(document.createTextNode(text.slice(0, prefix)));
    const mark = document.createElement('mark'); mark.className = color;
    mark.textContent = text.slice(prefix, end) || '∅';
    content.append(mark, document.createTextNode(text.slice(end)));
    row.append(title, content); box.append(row);
  }
}

function appearanceUnchanged(before, after) {
  return before?.id === after?.id && before?.filename === after?.filename &&
    before?.title === after?.title && JSON.stringify(before?.messages) === JSON.stringify(after?.messages);
}

async function syncCurrent() {
  if (!store.remote || !active) { syncStatus('Ноутбукта сақталды · GitHub қосылмаған'); return; }
  try {
    const before = active;
    const filename = await store.syncOne(active.filename);
    active = await store.open(filename);
    syncStatus('Ноутбукта және GitHub-та сақталды');
    await renderList();
    if (!appearanceUnchanged(before, active)) renderChat();
  } catch (error) {
    syncStatus('Ноутбукта сақталды · GitHub-ты қайта синхрондаңыз');
    message(error.message, true);
  }
}

async function run(task) {
  if (busy) return;
  setBusy(true); message('');
  try { await task(); }
  catch (error) { message(error.message || 'Әрекет орындалмады.', true); }
  finally { $('thinking')?.remove(); setBusy(false); }
}

async function synchronize() {
  assertUnlocked();
  if (!store.remote) throw new Error('GitHub аккаунтына кіру қажет.');
  const before = active;
  const selectedId = active?.id;
  syncStatus('GitHub синхрондалуда…');
  await store.syncAll();
  active = null;
  const names = await store.list();
  if (selectedId) for (const filename of names) {
    try { const chat = await store.open(filename); if (chat.id === selectedId) { active = chat; break; } } catch {}
  }
  if (!active && names.length) for (const filename of [...names].reverse()) {
    try { active = await store.open(filename); break; } catch {}
  }
  if (!appearanceUnchanged(before, active)) renderChat();
  await renderList(); syncStatus('Барлық чат GitHub-та сақталды');
}

let backgroundSync = false;
async function autoSync() {
  if (busy || backgroundSync || messageReview || !store?.remote) return;
  backgroundSync = true;
  try { await synchronize(); }
  catch (error) {
    syncStatus('Ноутбукта сақталды · GitHub әзірге синхрондалмады');
    message('GitHub синхрондау қатесі: ' + error.message, true);
  } finally { backgroundSync = false; }
}

async function activateSession(session) {
  if (!session.token) throw new Error('GitHub арқылы кіру қажет.');
  const selectedId = active?.id;
  legacyMaster = session.master || null;
  const remote = githubClient(session.token);
  // The remote refuses to write to a public repository.
  const candidate = new ChatStore(local, legacyMaster, remote);
  store = candidate;
  currentToken = session.token;
  $('login-screen').hidden = true;
  $('account-name').textContent = 'GitHub';
  $('account-detail').textContent = 'Private · аккаунт қосылды';
  $('lock-status').textContent = 'Аккаунт қосылды';
  const names = await store.list();
  active = null;
  if (selectedId) for (const filename of names) {
    try { const chat = await store.open(filename); if (chat.id === selectedId) { active = chat; break; } } catch {}
  }
  if (!active && names.length) {
    for (const filename of [...names].reverse()) {
      try { active = await store.open(filename); break; } catch {}
    }
  }
  renderChat(); await renderList();
  syncStatus('Аккаунт қосылды · GitHub тексерілуде…');
  await autoSync();
}
async function refreshSession() {
  if (busy || sessionCheck) return;
  sessionCheck = true;
  try {
    const session = await api('/api/session');
    if (!session.token) {
      store = null; currentToken = null; active = null;
      $('login-screen').hidden = false;
      $('login-hint').textContent = 'GitHub аккаунты арқылы кіру жеткілікті.';
      $('account-detail').textContent = 'Кіру қажет';
      renderChat();
    } else if (!store || session.token !== currentToken) {
      await activateSession(session);
    }
  } catch (error) {
    if (!store) $('login-screen').hidden = false;
    message(error.message || 'Аккаунтқа қосылу мүмкін болмады.', true);
  } finally { sessionCheck = false; }
}
$('new-chat').addEventListener('click', () => run(async () => {
  assertUnlocked();
  active = await store.create();
  renderChat(); await renderList();
  await syncCurrent();
  $('draft').focus();
}));

async function sendChat(optimizedPrompt = null) { return run(async () => {
  assertUnlocked();
  cancelTuze();
  $('tuze-status').textContent = 'Tuze өзі тексереді';
  const image = pendingImage;
  const text = $('draft').value.trim() || (image ? 'Бұл фотода не бар?' : '');
  if (!text) throw new Error('Хабарлама жазыңыз немесе фото тіркеңіз.');
  if (text.length > 4000) throw new Error('Хабарлама 4000 таңбадан аспасын.');
  if (!active) active = await store.create();
  active = await store.append(active.filename, 'user', text, image); // Local commit before model call.
  const sentId = active.messages.at(-1).id;
  $('draft').value = ''; fitDraft(); $('review').hidden = true; proposal = null;
  pendingImage = null; $('photo-input').value = ''; showPendingPhoto();
  renderChat(); await renderList();
  // Never wait for GitHub network sync before calling the local model.
  showThinking();
  // Keep the original words in history; send Logo&AI's reviewed English task to gpt-oss:20b.
  // A generated source file can be much longer than an ordinary message. Preserve the full
  // answer in storage, but bound what we send into the current local context window.
  const rawContext = active.messages.slice(-20).map(({id, role, content, image}) =>
    ({role, content: id === sentId && optimizedPrompt ? optimizedPrompt : content,
      ...(id === sentId && image ? {image} : {})}));
  const context = [];
  let budget = 14000;
  for (const entry of rawContext.reverse()) {
    if (budget < 200) break;
    const max = Math.min(entry.role === 'assistant' ? 11000 : 4000, budget);
    let content = entry.content;
    if (content.length > max) {
      const note = '\n[Алдыңғы ұзын кодтың жалғасы контекстке сыймады.]';
      content = content.slice(0, Math.max(1, max - note.length)) + note;
    }
    context.unshift({...entry, content});
    budget -= content.length;
  }
  const job = await api('/api/chat/start', {messages: context});
  if (!/^[a-f0-9]{32}$/.test(job.job_id || '')) throw new Error('gpt-oss:20b тапсырмасы басталмады.');
  let result = null;
  for (let attempt = 0; attempt < 900; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 1000));
    const status = await api(`/api/chat/result/${job.job_id}`);
    if (!status.done) {
      updateThinking(status.stage, status.partial);
      continue;
    }
    if (status.error) throw new Error(status.error);
    result = status.result;
    break;
  }
  if (!result?.text) throw new Error('gpt-oss:20b жауап бермеді. Чаттағы сұрақ сақталды.');
  active = await store.append(active.filename, 'assistant', result.text);
  renderChat(); await renderList();
  // Sync is optional and must not delay seeing the model's completed answer.
  queueMicrotask(() => { if (store?.remote) void syncCurrent(); });
}); }
$('send').addEventListener('click', () => { if (logoOriginal !== null) closeLogo(); void sendChat(); });

function showPendingPhoto() {
  $('photo-preview').replaceChildren();
  $('photo-preview').hidden = !pendingImage;
  $('remove-photo').hidden = !pendingImage;
  if (!pendingImage) return;
  const img = document.createElement('img');
  img.src = `data:image/jpeg;base64,${pendingImage.data}`;
  img.alt = 'Жіберілетін фото';
  $('photo-preview').append(img);
}

async function preparePhoto(file) {
  if (!file.type.startsWith('image/') || file.size > 12_000_000) {
    throw new Error('12 МБ-тан кіші фото таңдаңыз.');
  }
  let bitmap;
  try { bitmap = await createImageBitmap(file); }
  catch { throw new Error('Бұл фото пішімі ашылмады. JPEG немесе PNG таңдаңыз.'); }
  try {
    for (const limit of [1024, 896, 768, 640]) {
      const scale = Math.min(1, limit / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      for (const quality of [0.78, 0.63, 0.48]) {
        const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', quality));
        if (!blob) throw new Error('Фотоны өңдеу мүмкін болмады.');
        if (blob.size > 140_000) continue;
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 8192) {
          binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        }
        return {mime: 'image/jpeg', data: btoa(binary), width: canvas.width, height: canvas.height};
      }
    }
    throw new Error('Фото тым күрделі: кішірек сурет таңдаңыз.');
  } finally { bitmap.close(); }
}

// Logo&AI never silently changes what the user wrote: it asks questions, shows English,
// and sends only after the user confirms the translated instruction.
function closeLogo() {
  logoRevision++;
  logoLoading = false;
  logoOriginal = null;
  logoQuestions = [];
  $('logo-panel').hidden = true;
  $('logo-questions').replaceChildren();
}
function logoSetBusy(loading, label) {
  logoLoading = loading;
  $('logo-ai').disabled = loading;
  $('logo-build').disabled = loading;
  $('logo-send').disabled = loading;
  if (label !== undefined) $('logo-status').textContent = label;
}
async function logoJob(stage, original, answers, revision) {
  const job = await api('/api/logo/start', {stage, text:original, answers});
  if (!/^[a-f0-9]{32}$/.test(job.job_id || '')) throw new Error('Logo&AI тапсырмасы іске қосылмады.');
  for (let i=0; i<900; i++) {
    if (logoRevision !== revision) return null;
    await new Promise(resolve => setTimeout(resolve, 1000));
    const data = await api(`/api/logo/result/${job.job_id}`);
    if (data.done) {
      if (data.error) throw new Error(data.error);
      if (!data.result || typeof data.result.prompt_en !== 'string' ||
          typeof data.result.interpreted_kk !== 'string' ||
          !Array.isArray(data.result.questions)) throw new Error('Logo&AI жауап пішімі сәйкес емес.');
      return data.result;
    }
  }
  throw new Error('Logo&AI уақытында жауап бермеді. Ollama-ны тексер.');
}
function logoShowResult(data, allowQuestions) {
  $('logo-understanding').hidden = false;
  $('logo-understanding').textContent = 'Түсінгенім: ' + (data.interpreted_kk || 'Тапсырма толық түсінікті емес.');
  $('logo-prompt').value = data.prompt_en;
  $('logo-prompt').hidden = false;
  document.querySelector('.logo-prompt-label').hidden = false;
  $('logo-send').hidden = false;
  logoQuestions = allowQuestions ? data.questions.slice(0,3) : [];
  $('logo-questions').replaceChildren();
  if (logoQuestions.length) {
    const heading = document.createElement('div'); heading.className = 'logo-questions-title';
    heading.textContent = 'Осы сұрақтарға жауап берсең, тапсырма дәлірек болады:';
    $('logo-questions').append(heading);
    for (let i=0; i<logoQuestions.length; i++) {
      const wrap = document.createElement('label'); wrap.className = 'logo-question';
      const question = document.createElement('span'); question.textContent = `${i+1}. ${logoQuestions[i]}`;
      const input = document.createElement('input'); input.type = 'text'; input.maxLength = 500;
      input.placeholder = 'Жауабың (білмесең бос қалдыр)'; input.dataset.logoQuestion = String(i);
      wrap.append(question,input); $('logo-questions').append(wrap);
    }
    $('logo-questions').hidden = false;
    $('logo-build').hidden = false;
    $('logo-status').textContent = 'Сұрақтарға жауап бер де, «Жауаптарды ескеріп дайындау» батырмасын бас. Немесе қазіргі нұсқаны тексеріп жібер.';
  } else {
    $('logo-questions').hidden = true;
    $('logo-build').hidden = true;
    $('logo-status').textContent = data.uncertain ?
      'Модель мағынасына күмәнданды. Ағылшынша нұсқаны тексеріп, қажет жерін түзет.' :
      'Ағылшынша тапсырма дайын. Тексеріп, gpt-oss:20b-ге жібер.';
  }
}
$('logo-ai').addEventListener('click', async () => {
  const original = $('draft').value.trim();
  if (!original) { $('tuze-status').textContent = 'Алдымен өз ойыңды жаз.'; $('draft').focus(); return; }
  if (busy || logoLoading) return;
  cancelTuze(); // prevent auto-correction from interfering with the original wording
  const revision = ++logoRevision;
  logoOriginal = original;
  window.__logoChatId = active?.id;
  logoQuestions = [];
  $('logo-panel').hidden = false;
  $('logo-understanding').hidden = true;
  $('logo-questions').hidden = true; $('logo-questions').replaceChildren();
  $('logo-prompt').hidden = true; $('logo-prompt').value = '';
  document.querySelector('.logo-prompt-label').hidden = true;
  $('logo-build').hidden = true; $('logo-send').hidden = true;
  logoSetBusy(true, 'gpt-oss:20b мәтініңді түсінуге тырысып, қажет болса сұрақ дайындап жатыр…');
  try {
    const data = await logoJob('analyze', original, [], revision);
    if (logoRevision !== revision || !data) return;
    logoShowResult(data, true);
  } catch(error) {
    if (logoRevision !== revision) return;
    $('logo-status').textContent = 'Қате: ' + (error.message || 'Logo&AI жұмыс істемеді.');
  } finally { if (logoRevision === revision) logoSetBusy(false); }
});
$('logo-build').addEventListener('click', async () => {
  if (!logoOriginal || logoLoading || busy) return;
  if ($('draft').value.trim() !== logoOriginal) { $('logo-status').textContent = 'Мәтін өзгерген. Logo&AI-ды қайта бас.'; return; }
  const revision = ++logoRevision;
  const answers = [...$('logo-questions').querySelectorAll('input')].map(input => ({
    question: logoQuestions[Number(input.dataset.logoQuestion)], answer: input.value.trim()
  }));
  logoSetBusy(true, 'Жауаптарыңды қосып, gpt-oss:20b үшін ағылшынша тапсырма құрастырып жатыр…');
  try {
    const data = await logoJob('build', logoOriginal, answers, revision);
    if (logoRevision !== revision || !data) return;
    logoShowResult(data, false);
    $('logo-status').textContent = 'Жауаптарың ескерілді. Дайын тапсырманы тексеріп, жібер.';
  } catch(error) {
    if (logoRevision !== revision) return;
    $('logo-status').textContent = 'Қате: ' + (error.message || 'Тапсырма дайындалмады.');
  } finally { if (logoRevision === revision) logoSetBusy(false); }
});
$('logo-send').addEventListener('click', () => {
  if (logoLoading || busy) return;
  if (!logoOriginal || $('draft').value.trim() !== logoOriginal) {
    $('logo-status').textContent = 'Бастапқы мәтін өзгерген. Logo&AI-ды қайта бас.'; return;
  }
  const translated = $('logo-prompt').value.trim();
  if (translated.length < 5 || translated.length > 3600) {
    $('logo-status').textContent = 'Ағылшынша тапсырма 5–3600 таңба болуы керек.'; return;
  }
  closeLogo();
  void sendChat(translated);
});
$('logo-close').addEventListener('click', closeLogo);
$('photo-input').addEventListener('change', () => run(async () => {
  const file = $('photo-input').files?.[0];
  if (!file) return;
  pendingImage = await preparePhoto(file);
  showPendingPhoto();
}));
$('remove-photo').addEventListener('click', () => {
  pendingImage = null; $('photo-input').value = ''; showPendingPhoto();
});

$('draft').addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.ctrlKey || !event.shiftKey)) {
    event.preventDefault(); $('send').click();
  }
});

function cancelTuze() {
  tuzeRevision++;
  clearTimeout(tuzeTimer);
  proposal = null;
  proposalOriginal = null;
  $('review').hidden = true;
}

function scheduleTuze() {
  if (logoOriginal !== null) return;
  cancelTuze();
  const text = $('draft').value;
  if (!correctEnabled) return;
  if (!text.trim()) { $('tuze-status').textContent = 'Tuze өзі тексереді'; return; }
  if (text.length > 1200) { $('tuze-status').textContent = 'Tuze 1200 таңбаға дейін тексереді'; return; }
  if (text.trim().length < 3) return;
  const revision = tuzeRevision;
  const mode = $('tuze-mode').value;
  $('tuze-status').textContent = tuzeInFlight ? 'Tuze алдыңғы тексеруді аяқтауда…' : 'Tuze тексереді…';
  if (tuzeInFlight) return;
  tuzeTimer = setTimeout(() => { void checkTuze(text, mode, revision); }, 950);
}

async function checkTuze(text, mode, revision, force = false) {
  if (busy || (!correctEnabled && !force) || tuzeInFlight || revision !== tuzeRevision) return;
  tuzeInFlight = true;
  try {
    $('tuze-status').textContent = 'TUZE мәтінді өңдеп жатыр…';
    const job = await api('/api/tuze/start', {text, mode});
    if (!/^[a-f0-9]{32}$/.test(job.job_id || '')) throw new Error('TUZE тапсырма нөмірін қайтармады.');
    let data = null;
    for (let attempt = 0; attempt < 900; attempt++) {
      if (revision !== tuzeRevision || $('draft').value !== text || $('tuze-mode').value !== mode) return;
      await new Promise(resolve => setTimeout(resolve, 1000));
      data = await api(`/api/tuze/result/${job.job_id}`);
      if (data.done) break;
    }
    if (!data?.done) throw new Error('TUZE жауабы кешікті. Ollama моделін тексеріңіз.');
    if (data.error) throw new Error(data.error);
    data = data.result;
    if (revision !== tuzeRevision || $('draft').value !== text || $('tuze-mode').value !== mode) return;
    proposal = data.suggested_text || data.corrected_text;
    proposalOriginal = text;
    drawDifference(text, proposal);
    $('review-note').textContent = (data.warnings || []).join(' ') ||
      (proposal === text ? 'Өзгеріс жоқ.' : 'Өзгерісті тексеріп, қаласаңыз қолданыңыз.');
    $('review').hidden = false;
    $('apply').disabled = proposal === text;
    $('tuze-status').textContent = 'Tuze ұсынысы дайын';
  } catch (error) {
    if (revision === tuzeRevision) {
      $('tuze-status').textContent = 'Tuze: ' + (error.message || 'қате');
    }
  } finally {
    tuzeInFlight = false;
    if (revision !== tuzeRevision && logoOriginal === null && $('draft').value.trim() && !busy) scheduleTuze();
  }
}

$('correct-now').addEventListener('click', () => {
  if (!$('draft').value.trim()) { $('tuze-status').textContent = 'Алдымен мәтін жазыңыз.'; $('draft').focus(); return; }
  if ($('draft').value.length > 1200) { $('tuze-status').textContent = 'Түзету 1200 таңбаға дейін жұмыс істейді.'; return; }
  cancelTuze();
  if (tuzeInFlight) { $('tuze-status').textContent = 'Алдыңғы тексеру аяқталуда…'; return; }
  void checkTuze($('draft').value, $('tuze-mode').value, tuzeRevision, true);
});
$('draft').addEventListener('input', () => { if (logoOriginal !== null && $('draft').value.trim() !== logoOriginal) closeLogo(); scheduleTuze(); });
$('tuze-mode').addEventListener('change', scheduleTuze);

$('apply').addEventListener('click', () => {
  if (proposal !== null && $('draft').value === proposalOriginal) $('draft').value = proposal;
  cancelTuze(); $('tuze-status').textContent = 'Tuze өзгерісі қолданылды'; $('draft').focus();
});
$('dismiss').addEventListener('click', () => {
  cancelTuze(); $('tuze-status').textContent = 'Tuze өзгерісі қалдырылды';
});

async function health() {
  try { const res = await fetch('/api/health'); const data = await res.json();
    $('model-status').textContent = data.ready ? `${data.model} · орнатылған` : data.message;
    $('photo-status').textContent = data.vision_ready ?
      `${data.vision_model} · фотоны талдайды` :
      'Фото жіберіледі; талдау үшін qwen3-vl:4b-instruct орнатыңыз'; }
  catch { $('model-status').textContent = 'Ollama байланысы жоқ'; }
}
function setCollapsed(value) {
  $('sidebar').classList.toggle('closed', value);
  $('expand').hidden = !value;
}
function fitDraft() {
  const el = $('draft'); el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 210) + 'px';
}
$('new-chat-top').addEventListener('click', () => $('new-chat').click());
$('search').addEventListener('input', () => { void renderList(); });
$('collapse').addEventListener('click', () => setCollapsed(true));
$('expand').addEventListener('click', () => setCollapsed(false));
$('draft').addEventListener('input', fitDraft);
$('correct-toggle').addEventListener('click', () => {
  correctEnabled = !correctEnabled;
  $('correct-toggle').setAttribute('aria-pressed', String(correctEnabled));
  if (!correctEnabled) { cancelTuze(); $('tuze-status').textContent = 'Tuze түзетуі сөндірулі'; }
  else { $('tuze-status').textContent = 'TUZE қателерді тексереді'; scheduleTuze(); }
});
$('login').addEventListener('click', async () => {
  $('login').disabled = true;
  $('login-hint').textContent = 'Ресми GitHub беті ашылады. Терминалда бір реттік код шығуы мүмкін. Кодты тек github.com/login/device бетіне енгіз.';
  try { await api('/api/login', {}); }
  catch (error) { $('login-hint').textContent = error.message; $('login').disabled = false; return; }
  if (!loginPoll) loginPoll = setInterval(() => {
    void api('/api/login/status').then(state => {
      if (state.error) $('login-hint').textContent = state.error;
      else if (state.waiting) $('login-hint').textContent = 'GitHub-тан кіруді аяқта. Браузердегі авторизациядан кейін TUZE өзі ашылады.';
      return refreshSession();
    }).then(() => {
      if (store) { clearInterval(loginPoll); loginPoll = null; $('login').disabled = false; }
    }).catch(error=>{$('login-hint').textContent=error.message;});
  }, 2000);
  $('login').disabled = false;
});
$('account-button').addEventListener('click', () => {
  if (!store) $('login').click();
  else message('GitHub қосылған. Чаттар Tuze-Private-Chats жеке қоймасына сақталады.');
});
$('theme').addEventListener('click', () => {
  document.body.classList.toggle('dark');
  localStorage.setItem('tuze-theme', document.body.classList.contains('dark') ? 'dark' : 'light');
});
if (localStorage.getItem('tuze-theme') === 'dark') document.body.classList.add('dark');
if (window.innerWidth <= 700) setCollapsed(true);
fitDraft(); renderChat(); void refreshSession(); health();
window.addEventListener('online', () => { void refreshSession(); void autoSync(); });
setInterval(() => { void refreshSession(); }, 30_000);
setInterval(() => { void autoSync(); }, 120_000);
