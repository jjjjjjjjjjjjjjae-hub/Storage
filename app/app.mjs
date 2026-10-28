import { ChatStore, localClient, githubClient } from './store.mjs';

const $ = id => document.getElementById(id);
const local = localClient();
let store = null;
let active = null;
let busy = false;
let proposal = null;

function message(text, error = false) {
  $('notice').textContent = text;
  $('notice').classList.toggle('error', error);
  $('notice').hidden = !text;
}
function syncStatus(text) { $('sync-status').textContent = text; }
function setBusy(value) {
  busy = value;
  for (const id of ['new-chat','sync','send','tuze','unlock']) $(id).disabled = value;
  $('draft').disabled = value;
}
function assertUnlocked() {
  if (!store) throw new Error('Алдымен кілтсөзді енгізіңіз.');
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
    entry.append(role, body); list.append(entry);
  }
  if (!active) list.textContent = 'Кілтсөзді енгізіп, чатты ашыңыз немесе жаңасын жасаңыз.';
  list.scrollTop = list.scrollHeight;
}

function drawDifference(original, corrected) {
  const box = $('difference'); box.replaceChildren();
  let prefix = 0;
  while (prefix < Math.min(original.length, corrected.length) && original[prefix] === corrected[prefix]) prefix++;
  let left = original.length, right = corrected.length;
  while (left > prefix && right > prefix && original[left - 1] === corrected[right - 1]) { left--; right--; }
  for (const [label, text, end, color] of [
    ['Бұрын', original, left, 'old'], ['Tuze ұсынған', corrected, right, 'new'],
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

$('unlock').addEventListener('click', () => run(async () => {
  const passphrase = $('passphrase').value;
  if (passphrase.length < 12) throw new Error('Кілтсөз кемінде 12 таңба болсын. Оны жоғалтпаңыз.');
  const token = $('token').value.trim();
  const candidate = new ChatStore(local, passphrase, token ? githubClient(token) : null);
  const files = await candidate.list();
  if (files.length) await candidate.open(files[0]); // Verify before replacing the active key.
  store = candidate; $('passphrase').value = ''; $('token').value = '';
  $('lock-status').textContent = token ? 'Ашылды · GitHub қосылды' : 'Ашылды · ноутбукта';
  syncStatus(token ? 'Синхрондау батырмасын басыңыз' : 'GitHub үшін токенді енгізіп, қайта ашыңыз');
  active = files.length ? await store.open(files[0]) : null;
  renderChat(); await renderList();
}));

$('new-chat').addEventListener('click', () => run(async () => {
  assertUnlocked();
  active = await store.create();
  renderChat(); await renderList();
  await syncCurrent();
  $('draft').focus();
}));

$('sync').addEventListener('click', () => run(async () => {
  assertUnlocked();
  if (!store.remote) throw new Error('GitHub токенін енгізіп, «Ашу» батырмасын басыңыз.');
  const selectedId = active?.id;
  await store.syncAll();
  active = null;
  if (selectedId) for (const filename of await store.list()) {
    const chat = await store.open(filename);
    if (chat.id === selectedId) { active = chat; break; }
  }
  renderChat(); await renderList(); syncStatus('Барлық чат синхрондалды');
}));

$('send').addEventListener('click', () => run(async () => {
  assertUnlocked();
  const text = $('draft').value.trim();
  if (!text) throw new Error('Хабарлама жазыңыз.');
  if (text.length > 4000) throw new Error('Хабарлама 4000 таңбадан аспасын.');
  if (!active) active = await store.create();
  active = await store.append(active.filename, 'user', text); // Local commit before model call.
  $('draft').value = ''; $('review').hidden = true; proposal = null;
  renderChat(); await renderList();
  await syncCurrent();
  const context = active.messages.slice(-40).map(({role, content}) => ({role, content}));
  const response = await fetch('/api/chat', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({messages: context}) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Модель жауап бермеді. Сұрағыңыз сақталды.');
  active = await store.append(active.filename, 'assistant', data.text);
  renderChat(); await renderList(); await syncCurrent();
}));

$('draft').addEventListener('keydown', event => {
  if (event.ctrlKey && event.key === 'Enter') { event.preventDefault(); $('send').click(); }
});

$('tuze').addEventListener('click', () => run(async () => {
  const text = $('draft').value;
  if (!text.trim()) throw new Error('Алдымен түзететін мәтінді жазыңыз.');
  if (text.length > 1200) throw new Error('Tuze 1200 таңбаға дейін түзетеді.');
  const response = await fetch('/api/tuze', { method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({text, mode: $('tuze-mode').value}) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Tuze жауабы алынбады.');
  proposal = data.suggested_text || data.corrected_text;
  drawDifference(text, proposal);
  $('review-note').textContent = (data.warnings || []).join(' ') ||
    (proposal === text ? 'Өзгеріс жоқ.' : 'Өзгерісті қарап, қабылдасаңыз ғана қолданамыз.');
  $('review').hidden = false;
  $('apply').disabled = proposal === text;
}));

$('apply').addEventListener('click', () => {
  if (proposal !== null) $('draft').value = proposal;
  $('review').hidden = true; proposal = null; $('draft').focus();
});
$('dismiss').addEventListener('click', () => { $('review').hidden = true; proposal = null; });

async function health() {
  try { const res = await fetch('/api/health'); const data = await res.json();
    $('model-status').textContent = data.ready ? `${data.model} · дайын` : data.message; }
  catch { $('model-status').textContent = 'Ollama байланысы жоқ'; }
}
renderChat(); renderList().catch(error => message(error.message, true)); health();
