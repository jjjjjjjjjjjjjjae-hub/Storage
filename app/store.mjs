import { encryptChat, decryptChat, newChat, nextFilename, FILE_RE } from './crypto.mjs';

export class ConflictError extends Error {}

function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

export function mergeChats(a, b) {
  if (a.id !== b.id || a.filename !== b.filename) {
    throw new Error('Екі бөлек чат бір файлға түскен. Автоматты араластыруға тыйым салынды.');
  }
  const messages = new Map();
  for (const message of [...a.messages, ...b.messages]) {
    const old = messages.get(message.id);
    if (old && !same(old, message)) {
      throw new Error('Бір хабарламаның екі түрлі нұсқасы бар. Ешбірі өшірілген жоқ; сақтауды тоқтаттым.');
    }
    messages.set(message.id, message);
  }
  const ordered = [...messages.values()].sort((x, y) =>
    x.created_at.localeCompare(y.created_at) || x.id.localeCompare(y.id));
  const latest = a.updated_at > b.updated_at ? a : b.updated_at > a.updated_at ? b :
    a.title.localeCompare(b.title) >= 0 ? a : b;
  return { schema_version: 2, id: a.id, filename: a.filename,
    title: latest.title, created_at: a.created_at <= b.created_at ? a.created_at : b.created_at,
    updated_at: a.updated_at >= b.updated_at ? a.updated_at : b.updated_at, messages: ordered };
}

async function responseJson(response) {
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 409 || response.status === 422) throw new ConflictError(data.error || 'Нұсқалар қақтығысты.');
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

export function localClient(base = '') {
  return {
    async list() { return (await responseJson(await fetch(`${base}/api/local`))).files; },
    async get(filename) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      const res = await fetch(`${base}/api/local/${filename}`, { cache: 'no-store' });
      if (res.status === 404) return null;
      return (await responseJson(res)).envelope;
    },
    async put(filename, envelope, expectedVersion) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      return responseJson(await fetch(`${base}/api/local/${filename}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ envelope, expected_version: expectedVersion }),
      }));
    },
    async retire(filename, expectedVersion) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      return responseJson(await fetch(`${base}/api/retire/${filename}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ expected_version: expectedVersion }),
      }));
    },
  };
}

const API = 'https://api.github.com/repos/jjjjjjjjjjjjjjae-hub/Storage/contents/chats';
function base64Utf8(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}
function decodeBase64(value) {
  const binary = atob(value.replace(/\s/g, ''));
  return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(binary, c => c.charCodeAt(0)));
}

export function githubClient(token, request = fetch) {
  if (!token || typeof token !== 'string') throw new Error('GitHub токені керек.');
  const headers = { Authorization: `Bearer ${token.trim()}`,
    Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  async function call(url, options = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20_000);
    try {
      const res = await request(url, { ...options, cache: 'no-store', signal:controller.signal,
        headers: { ...headers, ...(options.headers || {}) } });
      if (res.status === 404) return null;
      return responseJson(res);
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('GitHub жауап бермеді. Чат ноутбукта сақталды.');
      throw error;
    } finally { clearTimeout(timer); }
  }
  return {
    async list() {
      const result = await call(API);
      if (!Array.isArray(result)) throw new Error('GitHub-та chats қалтасы табылмады.');
      return result.filter(x => x.type === 'file' && FILE_RE.test(x.name)).map(x => x.name);
    },
    async get(filename) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      const data = await call(`${API}/${filename}`);
      if (!data) return null;
      if (data.encoding !== 'base64' || typeof data.content !== 'string') throw new Error('GitHub файлын оқу мүмкін емес.');
      const envelope = JSON.parse(decodeBase64(data.content));
      if (envelope.filename !== filename) throw new Error('GitHub-тағы чат файлының атауы сәйкес емес.');
      return { envelope, sha: data.sha };
    },
    async put(filename, envelope, sha = null) {
      if (!FILE_RE.test(filename) || envelope.filename !== filename) throw new Error('Чат файлы сәйкес емес.');
      const body = { message: `Save encrypted ${filename}`, content: base64Utf8(JSON.stringify(envelope)), branch: 'main' };
      if (sha) body.sha = sha;
      const data = await call(`${API}/${filename}`, { method: 'PUT',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      if (!data?.content?.sha) throw new Error('GitHub сақтауды растамады.');
      return data.content.sha;
    },
  };
}

export class ChatStore {
  constructor(local, passphrase, remote = null) {
    this.local = local;
    this.passphrase = passphrase;
    this.remote = remote;
  }

  async list() { return this.local.list(); }

  async open(filename) {
    const envelope = await this.local.get(filename);
    if (!envelope) throw new Error('Чат жергілікті жерде табылмады. GitHub синхрондауын орындаңыз.');
    return decryptChat(envelope, this.passphrase, filename);
  }

  async create() {
    const names = new Set(await this.local.list());
    if (this.remote) {
      try { for (const name of await this.remote.list()) names.add(name); }
      catch { /* A chat must still be creatable offline; sync resolves numeric collisions. */ }
    }
    for (let attempt = 0; attempt < 10; attempt++) {
      const chat = newChat(nextFilename(names));
      const envelope = await encryptChat(chat, this.passphrase);
      try {
        await this.local.put(chat.filename, envelope, null);
        return chat;
      } catch (error) {
        if (!(error instanceof ConflictError)) throw error;
        names.add(chat.filename);
      }
    }
    throw new Error('Бос чат файлының атауы табылмады.');
  }

  async save(chat) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const current = await this.local.get(chat.filename);
      if (!current) throw new Error('Чат файлы жоғалған. Ештеңе жазылмады.');
      const old = await decryptChat(current, this.passphrase, chat.filename);
      chat = mergeChats(old, chat);
      const next = await encryptChat(chat, this.passphrase);
      try {
        await this.local.put(chat.filename, next, current.version);
        return chat;
      } catch (error) { if (!(error instanceof ConflictError)) throw error; }
    }
    throw new Error('Жергілікті сақтау қайшылығы. Чат өзгертілмеді, қайта көріңіз.');
  }

  async append(filename, role, content, image = null) {
    const chat = await this.open(filename);
    const now = new Date().toISOString();
    const item = { id: crypto.randomUUID(), role, content, created_at: now };
    if (image) item.image = image;
    chat.messages.push(item);
    if (chat.title === 'Жаңа чат' && role === 'user') chat.title = content.slice(0, 48).trim() || 'Жаңа чат';
    chat.updated_at = now;
    return this.save(chat);
  }

  async moveAside(localEnvelope, remoteFilenames) {
    const oldFilename = localEnvelope.filename;
    const chat = await decryptChat(localEnvelope, this.passphrase, oldFilename);
    const occupied = new Set([...(await this.local.list()), ...remoteFilenames]);
    for (let attempt = 0; attempt < 10; attempt++) {
      const filename = nextFilename(occupied);
      const renamed = { ...chat, filename };
      const next = await encryptChat(renamed, this.passphrase);
      try {
        await this.local.put(filename, next, null);
      } catch (error) {
        if (!(error instanceof ConflictError)) throw error;
        occupied.add(filename);
        continue;
      }
      await this.local.retire(oldFilename, localEnvelope.version);
      return filename;
    }
    throw new Error('Чат атауын қауіпсіз ауыстыру мүмкін болмады. Ескі файл сақталды.');
  }

  async syncOne(filename) {
    if (!this.remote) return filename;
    for (let attempt = 0; attempt < 5; attempt++) {
      const localEnvelope = await this.local.get(filename);
      if (!localEnvelope) throw new Error('Жергілікті файл жоғалған.');
      const localChat = await decryptChat(localEnvelope, this.passphrase, filename);
      const remote = await this.remote.get(filename);
      if (remote && remote.envelope.id !== localChat.id) {
        const newFilename = await this.moveAside(localEnvelope, await this.remote.list());
        await this.local.put(filename, remote.envelope, null);
        filename = newFilename;
        continue;
      }
      if (!remote) {
        try { await this.remote.put(filename, localEnvelope, null); return filename; }
        catch (error) { if (!(error instanceof ConflictError)) throw error; continue; }
      }
      const remoteChat = await decryptChat(remote.envelope, this.passphrase, filename);
      const merged = mergeChats(localChat, remoteChat);
      if (!same(merged, localChat)) {
        try { await this.local.put(filename, await encryptChat(merged, this.passphrase), localEnvelope.version); }
        catch (error) { if (!(error instanceof ConflictError)) throw error; continue; }
      }
      if (!same(merged, remoteChat)) {
        try { await this.remote.put(filename, await encryptChat(merged, this.passphrase), remote.sha); }
        catch (error) { if (!(error instanceof ConflictError)) throw error; continue; }
      }
      return filename;
    }
    throw new Error('GitHub-та сақтау қайшылығы. Жергілікті чат сақталды; қайта синхрондаңыз.');
  }

  async syncAll() {
    if (!this.remote) throw new Error('GitHub токенін енгізіңіз.');
    const remoteNames = await this.remote.list();
    for (const filename of remoteNames) {
      const remote = await this.remote.get(filename);
      if (!remote) continue;
      await decryptChat(remote.envelope, this.passphrase, filename);
      const local = await this.local.get(filename);
      if (!local) await this.local.put(filename, remote.envelope, null);
      else await this.syncOne(filename);
    }
    for (const filename of await this.local.list()) {
      if (!remoteNames.includes(filename)) await this.syncOne(filename);
    }
    return this.local.list();
  }
}
