// TUZE 2026 — account-only GitHub backup. New chats use JSON v3.
// GitHub destination is strictly a PRIVATE repository, never the old public Storage repo.
import { decryptChat, newChat, nextFilename, FILE_RE } from './crypto.mjs';

export class ConflictError extends Error {}
const clone = o => structuredClone(o);
const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
function assertChat(c, filename) {
  if (!c || ![2,3].includes(c.schema_version) || c.filename !== filename ||
      !/^[a-f\d-]{36}$/i.test(c.id) || typeof c.title !== 'string' ||
      !Array.isArray(c.messages) || typeof c.updated_at !== 'string' || typeof c.created_at !== 'string')
    throw new Error('Чат пішімі жарамсыз. Жазба өзгертілмеді.');
  if (c.messages.length > 10000) throw new Error('Чаттағы хабарламалар тым көп.');
  for (const m of c.messages) {
    if (!m || !/^[a-f\d-]{36}$/i.test(m.id) || !['user','assistant'].includes(m.role) ||
        typeof m.content !== 'string' || typeof m.created_at !== 'string' ||
        m.content.length > (m.role === 'assistant' ? 40000 : 4000))
      throw new Error('Чаттың хабарламасы жарамсыз.');
    if (m.edited_at !== undefined && (typeof m.edited_at !== 'string' || !Number.isFinite(Date.parse(m.edited_at)))) throw new Error('Түзету уақыты қате.');
    if (m.original_content !== undefined && (typeof m.original_content !== 'string' || m.original_content.length > 4000)) throw new Error('Бастапқы мәтін жарамсыз.');
    if (m.image && (m.role !== 'user' || m.image.mime !== 'image/jpeg' ||
       typeof m.image.data !== 'string' || m.image.data.length > 200_000 ||
       !/^[A-Za-z\d+/]+={0,2}$/.test(m.image.data))) throw new Error('Фото жарамсыз.');
  }
  return c;
}
function asChat3(chat) { return { ...chat, schema_version:3 }; }
function envelope(chat) { return { ...asChat3(chat), version:crypto.randomUUID() }; }
function stripVersion(file) { const {version, ...chat} = file; return chat; }

export function mergeChats(a, b) {
  if (a.id !== b.id || a.filename !== b.filename)
    throw new Error('Басқа чаттың үстіне жазуға болмайды.');
  const messages = new Map();
  for (const m of [...a.messages,...b.messages]) {
    const before = messages.get(m.id);
    if (before && !same(before,m)) {
      // A local correction and the same unedited message on GitHub are not a conflict.
      // Keep the newest explicit edit while retaining original_content for review.
      if (before.role !== m.role || before.created_at !== m.created_at || before.image?.data !== m.image?.data)
        throw new Error('Хабарлама сәйкессіздігі. Жазба сақталды.');
      if (before.content !== m.content && !before.edited_at && !m.edited_at)
        throw new Error('Түзетілмеген хабарламаларда қайшылық бар.');
      if (!before.edited_at || (m.edited_at && m.edited_at >= before.edited_at)) messages.set(m.id,m);
    } else { messages.set(m.id,m); }
  }
  const latest = a.updated_at >= b.updated_at ? a : b;
  return {schema_version:3,id:a.id,filename:a.filename,title:latest.title,
    created_at:a.created_at <= b.created_at ? a.created_at : b.created_at,
    updated_at:a.updated_at >= b.updated_at ? a.updated_at : b.updated_at,
    messages:[...messages.values()].sort((x,y)=>x.created_at.localeCompare(y.created_at))};
}
async function responseJson(response) {
  const data = await response.json().catch(()=>({}));
  if (!response.ok) {
    if ([409,422].includes(response.status)) throw new ConflictError(data.error || 'Нұсқалар қайшылығы.');
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}
export function localClient(base='') {
  return {
    async list() { return (await responseJson(await fetch(`${base}/api/local`,{cache:'no-store'}))).files; },
    async get(filename) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      const r = await fetch(`${base}/api/local/${filename}`,{cache:'no-store'});
      if (r.status===404) return null;
      return (await responseJson(r)).envelope;
    },
    async put(filename,file,expectedVersion) {
      if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
      return responseJson(await fetch(`${base}/api/local/${filename}`,{
        method:'PUT',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({envelope:file,expected_version:expectedVersion})}));
    },
    async retire(filename,expectedVersion) {
      return responseJson(await fetch(`${base}/api/retire/${filename}`,{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({expected_version:expectedVersion})}));
    }
  };
}
const REPO_NAME='Tuze-Private-Chats';
const ROOT='https://api.github.com';
function toB64(text) {
  const bytes=new TextEncoder().encode(text); let binary='';
  for(let i=0;i<bytes.length;i+=8192) binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
  return btoa(binary);
}
function fromB64(b64) {
  return new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(b64.replace(/\s/g,'')),c=>c.charCodeAt(0)));
}
export function githubClient(token,request=fetch) {
  if(typeof token!=='string' || token.length < 12) throw new Error('GitHub аккаунтына кіріңіз.');
  let repo=null;
  async function call(path,options={}) {
    const controller=new AbortController();
    const timer=setTimeout(()=>controller.abort(),25000);
    try {
      const res=await request(ROOT+path,{...options,cache:'no-store',signal:controller.signal,
        headers:{Authorization:`Bearer ${token.trim()}`,Accept:'application/vnd.github+json',
          'X-GitHub-Api-Version':'2022-11-28',...(options.headers||{})}});
      if(res.status===404) return null;
      return responseJson(res);
    } catch(error) {
      if(error.name==='AbortError') throw new Error('GitHub жауап бермеді. Жергілікті чат сақталады.');
      throw error;
    } finally { clearTimeout(timer); }
  }
  async function ensurePrivate() {
    if (!repo) {
      const user=await call('/user');
      if(!/^[A-Za-z\d-]+$/.test(user?.login||'')) throw new Error('GitHub аккаунты анықталмады.');
      repo=`/repos/${user.login}/${REPO_NAME}`;
    }
    let data=await call(repo);
    if(!data) {
      data=await call('/user/repos',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({name:REPO_NAME,private:true,auto_init:true,
          description:'TUZE жеке чаттарының резерв қоймасы'})});
    }
    if(data?.private!==true || data.name!==REPO_NAME) throw new Error(
      'Қауіпсіздік: Tuze-Private-Chats қоймасы Private емес. Чаттарды GitHub-қа жіберуге тыйым салынды.');
    return repo;
  }
  function filePath(filename) {if(!FILE_RE.test(filename))throw new Error('Файл атауы жарамсыз.');return `${repo}/contents/chats/${filename}`;}
  return {
    async ensure() { await ensurePrivate(); },
    async list() {
      await ensurePrivate(); const data=await call(`${repo}/contents/chats`);
      if(data===null)return []; // fresh private repository; no chats yet
      if(!Array.isArray(data)) throw new Error('GitHub chats қалтасы жарамсыз.');
      return data.filter(x=>x.type==='file'&&FILE_RE.test(x.name)).map(x=>x.name).sort();
    },
    async get(filename) {
      await ensurePrivate(); const data=await call(filePath(filename));
      if(!data)return null;
      if(data.encoding!=='base64'||typeof data.content!=='string') throw new Error('GitHub файлын оқу мүмкін емес.');
      const file=JSON.parse(fromB64(data.content));
      assertChat(file,filename);
      if(file.schema_version!==3) throw new Error('Private қоймада ескі чат табылды. Оны автоматты ауыстырмадым.');
      return {envelope:file,sha:data.sha};
    },
    async put(filename,file,sha=null) {
      assertChat(file,filename);
      if(file.schema_version!==3) throw new Error('Жаңа чат пішімі қажет.');
      await ensurePrivate(); // Re-check visibility on EACH write; public repos never receive plaintext
      const body={message:`TUZE chat ${filename}`,content:toB64(JSON.stringify(file)),branch:'main'};
      if(sha)body.sha=sha;
      const data=await call(filePath(filename),{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
      if(!data?.content?.sha)throw new Error('GitHub сақтауды растамады.');
      return data.content.sha;
    }
  };
}
export class ChatStore {
  constructor(local, legacyMaster=null,remote=null) { this.local=local;this.legacyMaster=legacyMaster;this.remote=remote; }
  async list(){return this.local.list();}
  async decode(file,filename) {
    if (!file) return null;
    if(file.schema_version===2) {
      if(!this.legacyMaster) throw new Error('Ескі шифрланған чат бұл құрылғыда ашылмайды. Оны бастапқы Windows құрылғысында көшіріңіз.');
      return asChat3(await decryptChat(file,this.legacyMaster,filename));
    }
    if(file.schema_version!==3) throw new Error('Чат нұсқасы белгісіз.');
    return asChat3(assertChat(stripVersion(file),filename));
  }
  async open(filename) {
    const file=await this.local.get(filename);
    if(!file)throw new Error('Чат табылмады.');
    return this.decode(file,filename);
  }
  async create() {
    const names=new Set(await this.list());
    if(this.remote)try{for(const name of await this.remote.list())names.add(name);}catch{}
    for(let i=0;i<10;i++){
      const chat=asChat3(newChat(nextFilename(names)));
      try {await this.local.put(chat.filename,envelope(chat),null);return chat;}
      catch(e){if(!(e instanceof ConflictError))throw e;names.add(chat.filename);}
    }
    throw new Error('Бос чат атауы табылмады.');
  }
  async save(chat) {
    for(let i=0;i<5;i++){
      const current=await this.local.get(chat.filename);
      if(!current)throw new Error('Чат файлы жоқ.');
      const merged=mergeChats(await this.decode(current,chat.filename),chat);
      try {await this.local.put(chat.filename,envelope(merged),current.version);return merged;}
      catch(e){if(!(e instanceof ConflictError))throw e;}
    }
    throw new Error('Жергілікті сақтау қайшылығы.');
  }
  async append(filename,role,content,image=null) {
    const chat=await this.open(filename),now=new Date().toISOString();
    const item={id:crypto.randomUUID(),role,content,created_at:now};
    if(image)item.image=image;
    chat.messages.push(item);
    if(chat.title==='Жаңа чат'&&role==='user')chat.title=content.slice(0,54).trim()||'Жаңа чат';
    chat.updated_at=now;return this.save(chat);
  }
  async editMessage(filename, messageId, expectedContent, correctedContent) {
    if (typeof correctedContent !== 'string' || !correctedContent.trim() || correctedContent.length > 4000)
      throw new Error('Түзетілген мәтін 1–4000 таңба болуы керек.');
    for (let attempt=0; attempt<5; attempt++) {
      const file=await this.local.get(filename);
      if (!file) throw new Error('Чат табылмады.');
      const chat=await this.decode(file,filename);
      const entry=chat.messages.find(m => m.id === messageId);
      if (!entry) throw new Error('Түзетілетін хабарлама табылмады.');
      if (entry.content !== expectedContent) throw new Error('Хабарлама өзгеріп кеткен. Түзетуді қайта бастаңыз.');
      if (entry.content === correctedContent) return chat;
      entry.original_content ??= entry.content;
      entry.content=correctedContent;
      entry.edited_at=new Date().toISOString();
      chat.updated_at=entry.edited_at;
      if (chat.messages[0]?.id===messageId && chat.messages[0]?.role==='user')
        chat.title=correctedContent.slice(0,54).trim()||chat.title;
      try { await this.local.put(filename,envelope(chat),file.version); return chat; }
      catch(e) { if(!(e instanceof ConflictError)) throw e; }
    }
    throw new Error('Түзету кезінде файл нұсқасы жаңарды. Қайталап көріңіз.');
  }
  async moveAside(localFile,remoteFilenames) {
    const chat=await this.decode(localFile,localFile.filename);
    const occupied=new Set([...(await this.local.list()),...remoteFilenames]);
    for(let i=0;i<10;i++){
      const filename=nextFilename(occupied),renamed={...chat,filename};
      try {await this.local.put(filename,envelope(renamed),null);}
      catch(e){if(!(e instanceof ConflictError))throw e;occupied.add(filename);continue;}
      await this.local.retire(localFile.filename,localFile.version);return filename;
    }
    throw new Error('Чаттың жаңа файлын жасау мүмкін болмады.');
  }
  async syncOne(filename) {
    if(!this.remote)return filename;
    for(let i=0;i<5;i++){
      const file=await this.local.get(filename),chat=await this.decode(file,filename);
      const other=await this.remote.get(filename);
      if(other&&other.envelope.id!==chat.id){
        const relocated=await this.moveAside(file,await this.remote.list());
        if(!await this.local.get(filename))await this.local.put(filename,other.envelope,null);
        filename=relocated;continue;
      }
      if(!other){
        try {
          await this.remote.put(filename,envelope(chat));
          if(file.schema_version===2) {
            try {await this.local.put(filename,envelope(chat),file.version);} catch(e){if(!(e instanceof ConflictError))throw e;}
          }
          return filename;
        }
        catch(e){if(!(e instanceof ConflictError))throw e;continue;}
      }
      const remoteChat=await this.decode(other.envelope,filename);
      const merged=mergeChats(chat,remoteChat);
      if(!same(merged,chat)) {
        try{await this.local.put(filename,envelope(merged),file.version);}
        catch(e){if(!(e instanceof ConflictError))throw e;continue;}
      } else if(file.schema_version===2){ // upgrade encrypted local file without deleting backups
        try {await this.local.put(filename,envelope(chat),file.version);}
        catch(e){if(!(e instanceof ConflictError))throw e;continue;}
      }
      if(!same(merged,remoteChat)){
        try {await this.remote.put(filename,envelope(merged),other.sha);}
        catch(e){if(!(e instanceof ConflictError))throw e;continue;}
      }
      return filename;
    }
    throw new Error('GitHub синхрондауы қайшы. Жергілікті файл сақталды.');
  }
  async syncAll() {
    if(!this.remote)throw new Error('GitHub аккаунтына кіріңіз.');
    const names=await this.remote.list();
    for(const filename of names) {
      const remote=await this.remote.get(filename);if(!remote)continue;
      const local=await this.local.get(filename);
      if(!local)await this.local.put(filename,remote.envelope,null);
      else await this.syncOne(filename);
    }
    for(const filename of await this.list()) if(!names.includes(filename))await this.syncOne(filename);
    return this.list();
  }
}
