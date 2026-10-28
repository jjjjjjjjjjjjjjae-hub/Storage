import { ChatStore, localClient, githubClient } from './store.mjs';
import { encryptChat, decryptChat } from './crypto.mjs';

const $ = id => document.getElementById(id);
const local = localClient();
let store = null;
let active = null;
let busy = false;
let proposal = null;
let pendingImage = null;
let master = null;
let tuzeTimer = null;
let tuzeRevision = 0;
let tuzeInFlight = false;
let proposalOriginal = null;

function message(text, error = false) {
  $('notice').textContent = text;
  $('notice').classList.toggle('error', error);
  $('notice').hidden = !text;
}
function syncStatus(text) { $('sync-status').textContent = text; }
function setBusy(value) {
  busy = value;
  for (const id of ['new-chat','sync','send','save-token','export-key','restore-key','migrate']) $(id).disabled = value;
  $('draft').disabled = value;
  $('photo-input').disabled = value;
  $('remove-photo').disabled = value;
}
function assertUnlocked() {
  if (!store) throw new Error('Кілт ашылмады. Қалпына келтіру бөлімін тексеріңіз.');
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
  const names = await local.list();
  $('chat-list').replaceChildren();
  for (const filename of names) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'chat-item' + (active?.filename === filename ? ' current' : '');
    button.textContent = active?.filename === filename && active.title !== 'Жаңа чат' ?
      `${filename} · ${active.title}` : filename;
    button.addEventListener('click', () => run(async () => {
      assertUnlocked();
      active = await store.open(filename);
      renderChat(); await renderList();
    }));
    $('chat-list').append(button);
  }
  if (!names.length) $('chat-list').textContent = 'Әзірге чат жоқ.';
}

function renderChat() {
  $('chat-title').textContent = active?.title || 'Чатты таңдаңыз';
  $('chat-file').textContent = active?.filename || 'Әр чат өзінің файлына сақталады.';
  const list = $('messages');
  list.replaceChildren();
  for (const item of active?.messages || []) {
    const entry = document.createElement('article');
    entry.className = 'message ' + item.role;
    const role = document.createElement('strong');
    role.textContent = item.role === 'user' ? 'Сен' : 'Qwen3';
    const body = document.createElement('p'); body.textContent = item.content;
    entry.append(role, body);
    if (item.image) {
      const photo = document.createElement('img');
      photo.src = `data:image/jpeg;base64,${item.image.data}`;
      photo.alt = 'Чатқа тіркелген фото';
      photo.className = 'chat-photo';
      entry.append(photo);
    }
    list.append(entry);
  }
  if (!active) list.textContent = store ? 'Чатты таңдаңыз немесе жаңасын бастаңыз.' : 'Чаттар ашылуда…';
  list.scrollTop = list.scrollHeight;
}

function drawDifference(original, corrected) {
  const box = $('difference'); box.replaceChildren();
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

async function syncCurrent() {
  if (!store.remote || !active) { syncStatus('Ноутбукта сақталды · GitHub қосылмаған'); return; }
  try {
    const filename = await store.syncOne(active.filename);
    active = await store.open(filename);
    syncStatus('Ноутбукта және GitHub-та сақталды');
    await renderList(); renderChat();
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
  finally { setBusy(false); }
}

async function synchronize() {
  assertUnlocked();
  if (!store.remote) throw new Error('GitHub токенін бір рет енгізіңіз.');
  const selectedId = active?.id;
  syncStatus('GitHub синхрондалуда…');
  await store.syncAll();
  active = null;
  const names = await store.list();
  if (selectedId) for (const filename of names) {
    const chat = await store.open(filename);
    if (chat.id === selectedId) { active = chat; break; }
  }
  if (!active && names.length) active = await store.open(names[0]);
  renderChat(); await renderList(); syncStatus('Барлық чат GitHub-та сақталды');
}

async function autoSync() {
  if (busy || !store?.remote) return;
  await run(async () => {
    try { await synchronize(); }
    catch (error) {
      syncStatus('Ноутбукта сақталды · GitHub әзірге синхрондалмады');
      if (error.message.includes('Кілтсөз қате')) showLegacy();
      throw error;
    }
  });
}

function showLegacy() {
  $('legacy-section').hidden = false;
  $('legacy-section').closest('details').open = true;
}

async function boot() {
  try {
    const session = await api('/api/session');
    if (typeof session.master !== 'string' || session.master.length < 40) throw new Error('Кілт жарамсыз.');
    master = session.master;
    const candidate = new ChatStore(local, master, session.token ? githubClient(session.token) : null);
    const files = await candidate.list();
    for (const filename of files) await candidate.open(filename); // Validate all before enabling writes.
    store = candidate;
    active = files.length ? await store.open(files[0]) : null;
    $('lock-status').textContent = 'Шифрлау автоматты · Windows-та қорғалған';
    syncStatus(store.remote ? 'GitHub қосылды · синхрондалуда…' : 'Ноутбукта сақталады · GitHub токенін бір рет қосыңыз');
    renderChat(); await renderList();
    if (store.remote) await autoSync();
  } catch (error) {
    $('lock-status').textContent = 'Кілтті қалпына келтіру керек';
    showLegacy();
    message(error.message || 'Чаттарды аша алмадым. Ештеңе өзгертілмеді.', true);
  }
}

$('save-token').addEventListener('click', () => run(async () => {
  assertUnlocked();
  const token = $('token').value.trim();
  if (!token) throw new Error('Storage репосына арналған GitHub токенін енгізіңіз.');
  await api('/api/token', {token});
  store.remote = githubClient(token);
  $('token').value = '';
  $('lock-status').textContent = 'Шифрлау автоматты · GitHub қосылды';
  try { await synchronize(); }
  catch (error) { syncStatus('Ноутбукта сақталды · GitHub синхрондау қатесі'); throw error; }
}));

$('export-key').addEventListener('click', () => run(async () => {
  if (!master) throw new Error('Кілт әлі ашылмады.');
  const url = URL.createObjectURL(new Blob([master + '\n'], {type:'text/plain'}));
  const link = document.createElement('a'); link.href = url; link.download = 'Tuze-қалпына-келтіру-кілті.txt';
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  message('Кілт жүктелді. Оны бөлек қауіпсіз жерде сақтаңыз.');
}));

$('restore-key').addEventListener('click', () => run(async () => {
  const replacement = $('import-key').value.trim();
  let bytes;
  try { bytes = Uint8Array.from(atob(replacement), char => char.charCodeAt(0)); }
  catch { throw new Error('Қалпына келтіру кілті жарамсыз.'); }
  if (bytes.length !== 32) throw new Error('Қалпына келтіру кілті жарамсыз.');
  const candidate = new ChatStore(local, replacement, store?.remote || null);
  for (const filename of await candidate.list()) await candidate.open(filename);
  await api('/api/recovery/import', {master:replacement});
  const session = await api('/api/session');
  candidate.remote = session.token ? githubClient(session.token) : null;
  $('import-key').value = ''; master = replacement; store = candidate;
  $('legacy-section').hidden = true;
  const names = await store.list(); active = names.length ? await store.open(names[0]) : null;
  $('lock-status').textContent = 'Кілт қалпына келтірілді · автоматты шифрлау';
  renderChat(); await renderList();
  if (store.remote) { try { await synchronize(); } catch (error) { syncStatus('GitHub синхрондау қатесі'); throw error; } }
}));

$('migrate').addEventListener('click', () => run(async () => {
  if (!master) throw new Error('Windows кілті ашылмады. Алдымен қалпына келтіру кілтін енгізіңіз.');
  const previous = $('legacy-passphrase').value;
  if (previous.length < 12) throw new Error('Бұрынғы кілтсөз кемінде 12 таңба болуы керек.');
  const session = await api('/api/session');
  const remote = session.token ? githubClient(session.token) : null;
  const names = await local.list();
  const pending = [];
  for (const filename of names) {
    const envelope = await local.get(filename);
    try { await new ChatStore(local, master).open(filename); }
    catch {
      const chat = await new ChatStore(local, previous).open(filename);
      pending.push({filename, version:envelope.version, envelope:await encryptChat(chat, master)});
    }
  }
  const pendingRemote = [];
  if (remote) for (const filename of await remote.list()) {
    const current = await remote.get(filename);
    if (!current) continue;
    try { await decryptChat(current.envelope, master, filename); }
    catch {
      const chat = await decryptChat(current.envelope, previous, filename);
      pendingRemote.push({filename, sha:current.sha, envelope:await encryptChat(chat, master)});
    }
  }
  for (const item of pending) await local.put(item.filename, item.envelope, item.version);
  for (const item of pendingRemote) await remote.put(item.filename, item.envelope, item.sha);
  $('legacy-passphrase').value = '';
  store = new ChatStore(local, master, remote);
  active = names.length ? await store.open(names[0]) : null;
  $('legacy-section').hidden = true;
  $('lock-status').textContent = 'Ескі чаттар көшірілді · автоматты шифрлау';
  renderChat(); await renderList();
  if (store.remote) { try { await synchronize(); } catch (error) { syncStatus('GitHub-тағы ескі чаттарды көшіру керек'); showLegacy(); throw error; } }
}));

$('new-chat').addEventListener('click', () => run(async () => {
  assertUnlocked();
  active = await store.create();
  renderChat(); await renderList();
  await syncCurrent();
  $('draft').focus();
}));

$('sync').addEventListener('click', () => run(async () => {
  try { await synchronize(); }
  catch (error) { syncStatus('Ноутбукта сақталды · GitHub синхрондау қатесі'); throw error; }
}));

$('send').addEventListener('click', () => run(async () => {
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
  $('draft').value = ''; $('review').hidden = true; proposal = null;
  pendingImage = null; $('photo-input').value = ''; showPendingPhoto();
  renderChat(); await renderList();
  await syncCurrent();
  const context = active.messages.slice(-40).map(({id, role, content, image}) =>
    ({role, content, ...(id === sentId && image ? {image} : {})}));
  const response = await fetch('/api/chat', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({messages: context}) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Модель жауап бермеді. Сұрағыңыз сақталды.');
  active = await store.append(active.filename, 'assistant', data.text);
  renderChat(); await renderList(); await syncCurrent();
}));

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
  if (event.ctrlKey && event.key === 'Enter') { event.preventDefault(); $('send').click(); }
});

function cancelTuze() {
  tuzeRevision++;
  clearTimeout(tuzeTimer);
  proposal = null;
  proposalOriginal = null;
  $('review').hidden = true;
}

function scheduleTuze() {
  cancelTuze();
  const text = $('draft').value;
  if (!text.trim()) { $('tuze-status').textContent = 'Tuze өзі тексереді'; return; }
  if (text.length > 1200) { $('tuze-status').textContent = 'Tuze 1200 таңбаға дейін тексереді'; return; }
  if (text.trim().length < 3) return;
  const revision = tuzeRevision;
  const mode = $('tuze-mode').value;
  $('tuze-status').textContent = tuzeInFlight ? 'Tuze алдыңғы тексеруді аяқтауда…' : 'Tuze тексереді…';
  if (tuzeInFlight) return;
  tuzeTimer = setTimeout(() => { void checkTuze(text, mode, revision); }, 1400);
}

async function checkTuze(text, mode, revision) {
  if (busy || !store || tuzeInFlight || revision !== tuzeRevision) return;
  tuzeInFlight = true;
  try {
    const response = await fetch('/api/tuze', { method:'POST',
      headers:{'Content-Type':'application/json'}, body:JSON.stringify({text,mode}) });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Tuze жауабы алынбады.');
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
    if (revision !== tuzeRevision && $('draft').value.trim() && !busy) scheduleTuze();
  }
}

$('draft').addEventListener('input', scheduleTuze);
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
    $('model-status').textContent = data.ready ? `${data.model} · мәтін дайын` : data.message;
    $('photo-status').textContent = data.vision_ready ?
      `${data.vision_model} · фотоны талдайды` :
      'Фото жіберіледі; талдау үшін qwen3-vl:4b-instruct орнатыңыз'; }
  catch { $('model-status').textContent = 'Ollama байланысы жоқ'; }
}
renderChat(); boot(); health();
window.addEventListener('online', () => { void autoSync(); });
setInterval(() => { void autoSync(); }, 120_000);
