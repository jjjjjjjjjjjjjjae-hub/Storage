import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { encryptChat, decryptChat, newChat, nextFilename } from '../app/crypto.mjs';
import { ChatStore, ConflictError, mergeChats } from '../app/store.mjs';

globalThis.crypto ??= webcrypto;
const password = 'ұзын-құпия-сөз-2026';
const clone = value => value === null ? null : structuredClone(value);

class MemoryLocal {
  files = new Map();
  async list() { return [...this.files.keys()].sort(); }
  async get(filename) { return clone(this.files.get(filename) || null); }
  async put(filename, envelope, expectedVersion) {
    const old = this.files.get(filename);
    if ((old?.version ?? null) !== (expectedVersion || null)) throw new ConflictError('local conflict');
    this.files.set(filename, clone(envelope));
    return { version: envelope.version };
  }
  async retire(filename, expectedVersion) {
    if (this.files.get(filename)?.version !== expectedVersion) throw new ConflictError('local conflict');
    this.files.delete(filename);
  }
}
class MemoryRemote {
  files = new Map();
  serial = 0;
  async list() { return [...this.files.keys()].sort(); }
  async get(filename) { return clone(this.files.get(filename) || null); }
  async put(filename, envelope, sha) {
    const old = this.files.get(filename);
    if ((old?.sha ?? null) !== (sha || null)) throw new ConflictError('remote conflict');
    const next = String(++this.serial);
    this.files.set(filename, { envelope: clone(envelope), sha: next });
    return next;
  }
}

test('encrypted file contains no plaintext and rejects wrong key or tampering', async () => {
  const chat = newChat('chat_001.json');
  chat.title = 'Құпия атау';
  chat.messages.push({ id: crypto.randomUUID(), role: 'user', content: 'Менің құпия хабарламам', created_at: chat.created_at });
  const envelope = await encryptChat(chat, password);
  assert.doesNotMatch(JSON.stringify(envelope), /Құпия|хабарламам/);
  assert.deepEqual(await decryptChat(envelope, password, 'chat_001.json'), chat);
  await assert.rejects(decryptChat(envelope, 'wrong-password-999', 'chat_001.json'), /Кілтсөз қате/);
  await assert.rejects(decryptChat(envelope, password, 'chat_002.json'), /сәйкес келмейді/);
  const tampered = clone(envelope); tampered.encryption.ciphertext = 'A' + tampered.encryption.ciphertext.slice(1);
  await assert.rejects(decryptChat(tampered, password, 'chat_001.json'), /Кілтсөз қате/);
});

test('returning to a chat appends only to its stable file', async () => {
  const local = new MemoryLocal(); const store = new ChatStore(local, password);
  const a = await store.create(); const b = await store.create();
  assert.equal(a.filename, 'chat_001.json'); assert.equal(b.filename, 'chat_002.json');
  await store.append(a.filename, 'user', 'Алғашқы чат');
  await store.append(b.filename, 'user', 'Екінші чат');
  await store.append(a.filename, 'assistant', 'Жауап тек біріншіде');
  assert.deepEqual((await store.open(a.filename)).messages.map(m => m.content), ['Алғашқы чат','Жауап тек біріншіде']);
  assert.deepEqual((await store.open(b.filename)).messages.map(m => m.content), ['Екінші чат']);
  assert.deepEqual(await store.list(), ['chat_001.json','chat_002.json']);
});

test('stale local saves merge unique message IDs without discarding either', async () => {
  const local = new MemoryLocal(); const store = new ChatStore(local, password);
  const a = await store.create();
  const stale = await store.open(a.filename);
  await store.append(a.filename, 'user', 'Жаңа хабарлама');
  stale.messages.push({ id: crypto.randomUUID(), role: 'assistant', content: 'Қатар келген жауап', created_at: new Date().toISOString() });
  stale.updated_at = new Date().toISOString();
  await store.save(stale);
  assert.equal((await store.open(a.filename)).messages.length, 2);
  const incompatible = structuredClone(stale); incompatible.id = crypto.randomUUID();
  assert.throws(() => mergeChats(a, incompatible), /Екі бөлек чат/);
});

test('GitHub conflict merges messages and preserves one file per chat', async () => {
  const local = new MemoryLocal(), remote = new MemoryRemote();
  const store = new ChatStore(local, password, remote);
  const chat = await store.create(); await store.syncOne(chat.filename);
  const remoteChat = await decryptChat((await remote.get(chat.filename)).envelope, password, chat.filename);
  remoteChat.messages.push({ id: crypto.randomUUID(), role: 'user', content: 'Басқа құрылғы', created_at: new Date().toISOString() });
  remoteChat.updated_at = new Date().toISOString();
  await remote.put(chat.filename, await encryptChat(remoteChat, password), (await remote.get(chat.filename)).sha);
  await store.append(chat.filename, 'user', 'Осы құрылғы');
  await store.syncOne(chat.filename);
  assert.deepEqual(new Set((await store.open(chat.filename)).messages.map(m => m.content)), new Set(['Басқа құрылғы','Осы құрылғы']));
  assert.equal((await remote.list()).length, 1);
});

test('numeric collision with another chat moves local chat to next free file', async () => {
  const local = new MemoryLocal(), remote = new MemoryRemote();
  const offline = new ChatStore(local, password);
  const mine = await offline.create(); await offline.append(mine.filename, 'user', 'Менің чатым');
  const someoneElse = newChat('chat_001.json');
  someoneElse.messages.push({ id: crypto.randomUUID(), role: 'user', content: 'Басқа чат', created_at: someoneElse.created_at });
  await remote.put('chat_001.json', await encryptChat(someoneElse, password), null);
  const connected = new ChatStore(local, password, remote);
  await connected.syncAll();
  assert.deepEqual(await local.list(), ['chat_001.json','chat_002.json']);
  assert.deepEqual(await remote.list(), ['chat_001.json','chat_002.json']);
  assert.equal((await connected.open('chat_001.json')).id, someoneElse.id);
  assert.equal((await connected.open('chat_002.json')).id, mine.id);
  assert.deepEqual((await connected.open('chat_002.json')).messages.map(m => m.content), ['Менің чатым']);
});

test('network outage does not prevent a new local chat', async () => {
  const local = new MemoryLocal();
  const remote = { async list() { throw new Error('offline'); } };
  const store = new ChatStore(local, password, remote);
  const chat = await store.create();
  assert.equal(chat.filename, nextFilename([]));
  assert.deepEqual(await store.list(), ['chat_001.json']);
});
