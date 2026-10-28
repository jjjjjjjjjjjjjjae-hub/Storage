import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const file = (name) => readFileSync(new URL('../'+name, import.meta.url), 'utf8');

test('gpt-oss:20b is the single configured text model', () => {
  const cfg=JSON.parse(file('app/config.json'));
  assert.equal(cfg.model, 'gpt-oss:20b');
  assert.ok(cfg.timeout_seconds >= 600);
  const start=file('Start-Storage.ps1');
  const core=file('app/tuze.ps1');
  assert.match(start, /gpt-oss:20b/);
  assert.match(core, /gpt-oss:20b/);
  assert.doesNotMatch(start+core, /qwen3:4b/);
});

test('20B chat is a background job and keeps the preview code path', () => {
  const server=file('app/server.ps1');
  const ui=file('app/app.mjs');
  const worker=file('app/chat-worker.ps1');
  assert.match(server, /'\/api\/chat\/start'/);
  assert.match(server, /'chat-worker.ps1'/);
  assert.match(server, /chat\)\/result/);
  assert.match(ui, /api\/chat\/start/);
  assert.match(ui, /api\/chat\/result/);
  assert.match(ui, /renderCodeWorkspace/);
  assert.match(worker, /Invoke-ChatModel/);
  assert.match(file('app/chat-model.ps1'), /think=\$thinking/);
  assert.match(file('app/tuze.ps1'), /think='low'/);
  assert.match(file('app/logo-ai.ps1'), /think = 'low'/);
});

test('Logo&AI and manual corrections stay available with automatic suggestions', () => {
  const ui=file('app/app.mjs');
  const doc=file('app/index.html');
  const logo=file('app/logo-ai.ps1');
  assert.match(ui, /let correctEnabled = true/);
  assert.match(doc, /id="correct-now"/);
  assert.match(doc, /id="logo-ai"/);
  assert.match(logo, /\$script:TuzeConfig\.model/);
});

test('20B chat shows partial tokens and does not block on GitHub sync', () => {
  const ui=file('app/app.mjs');
  const model=file('app/chat-model.ps1');
  const server=file('app/server.ps1');
  const send=ui.slice(ui.indexOf('async function sendChat('),ui.indexOf("$('send').addEventListener",ui.indexOf('async function sendChat(')));
  assert.match(send, /updateThinking\(status.stage, status.partial\)/);
  assert.doesNotMatch(send.slice(0,send.indexOf("api('/api/chat/start'")), /await syncCurrent\(\)/);
  assert.match(model,/function Invoke-TuzeOllamaStream/);
  assert.match(model,/Save-ChatProgress/);
  assert.match(server,/partial=\[string\]\$progress.text/);
});
