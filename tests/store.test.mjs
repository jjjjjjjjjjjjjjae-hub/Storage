import {test} from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {newChat, encryptChat} from '../app/crypto.mjs';
import {ChatStore,ConflictError,mergeChats,githubClient} from '../app/store.mjs';
globalThis.crypto ??= webcrypto;
const legacyKey='a-long-existing-local-windows-key';
const copy=x=>x===null?null:structuredClone(x);
class MemoryLocal {
  files=new Map();
  async list(){return [...this.files.keys()].sort();}
  async get(filename){return copy(this.files.get(filename)||null);}
  async put(filename,file,expectedVersion){
    const old=this.files.get(filename);
    if((old?.version??null)!==(expectedVersion||null))throw new ConflictError('local conflict');
    this.files.set(filename,copy(file));return {version:file.version};
  }
  async retire(filename,version){
    if(this.files.get(filename)?.version!==version)throw new ConflictError('local conflict');
    this.files.delete(filename);
  }
}
class MemoryRemote {
  files=new Map(); count=0;
  async list(){return [...this.files.keys()].sort();}
  async get(filename){return copy(this.files.get(filename)||null);}
  async put(filename,file,sha){
    const old=this.files.get(filename);
    if((old?.sha??null)!==(sha||null))throw new ConflictError('remote conflict');
    const next=String(++this.count);
    this.files.set(filename,{envelope:copy(file),sha:next});return next;
  }
}
const prepared=async(filename,content)=>{
  const c={...newChat(filename),schema_version:3};
  c.title=content;c.messages.push({id:crypto.randomUUID(),role:'user',content,created_at:c.created_at});return c;
};
test('account-only JSON v3 chats need no encryption passphrase',async()=>{
  const local=new MemoryLocal(), store=new ChatStore(local);
  const first=await store.create(),second=await store.create();
  assert.deepEqual([first.filename,second.filename],['chat_001.json','chat_002.json']);
  await store.append(first.filename,'user','Сәлем, TUZE');
  await store.append(first.filename,'assistant','Сәлем!');
  await store.append(second.filename,'user','Басқа чат');
  const f=await store.open(first.filename),s=await store.open(second.filename);
  assert.deepEqual(f.messages.map(x=>x.content),['Сәлем, TUZE','Сәлем!']);
  assert.deepEqual(s.messages.map(x=>x.content),['Басқа чат']);
  assert.equal((await local.get(first.filename)).schema_version,3);
});
test('new login on another device restores chat from private remote',async()=>{
  const remote=new MemoryRemote();
  const laptop=new ChatStore(new MemoryLocal(),null,remote);
  const chat=await laptop.create();await laptop.append(chat.filename,'user','Кросс-құрылғы');
  await laptop.syncAll();
  assert.equal((await remote.get(chat.filename)).envelope.schema_version,3);
  const secondLaptop=new ChatStore(new MemoryLocal(),null,remote);
  await secondLaptop.syncAll();
  assert.equal((await secondLaptop.open(chat.filename)).messages[0].content,'Кросс-құрылғы');
});
test('legacy encrypted chat migrates with original DPAPI key then new account needs no key',async()=>{
  const local=new MemoryLocal(),remote=new MemoryRemote();
  const old=await prepared('chat_001.json','Бұрынғы шифрланған чат');
  const oldFile=await encryptChat({...old,schema_version:2},legacyKey);
  await local.put(old.filename,oldFile,null);
  const original=new ChatStore(local,legacyKey,remote);
  await original.syncAll();
  assert.equal((await local.get(old.filename)).schema_version,3);
  assert.equal((await remote.get(old.filename)).envelope.title,old.title);
  const other=new ChatStore(new MemoryLocal(),null,remote);
  await other.syncAll();
  assert.equal((await other.open(old.filename)).title,old.title);
});
test('same-chat divergent messages merge without loss',async()=>{
  const local=new MemoryLocal(),remote=new MemoryRemote();
  const store=new ChatStore(local,null,remote);
  const chat=await store.create();await store.syncOne(chat.filename);
  const before=(await remote.get(chat.filename));
  const changed=copy(before.envelope);changed.messages.push({id:crypto.randomUUID(),role:'user',content:'Екінші құрылғы',created_at:changed.created_at});
  changed.version=crypto.randomUUID();
  await remote.put(chat.filename,changed,before.sha);
  await store.append(chat.filename,'user','Бірінші құрылғы');
  await store.syncOne(chat.filename);
  assert.deepEqual(new Set((await store.open(chat.filename)).messages.map(x=>x.content)),new Set(['Бірінші құрылғы','Екінші құрылғы']));
});
test('filename collisions are relocated rather than overwritten',async()=>{
  const local=new MemoryLocal(),remote=new MemoryRemote();
  const offline=new ChatStore(local);
  const mine=await offline.create();await offline.append(mine.filename,'user','Менікі');
  const another=await prepared('chat_001.json','Өзге');
  await remote.put(another.filename,{...another,version:crypto.randomUUID()},null);
  const connected=new ChatStore(local,null,remote);await connected.syncAll();
  assert.deepEqual(await connected.list(),['chat_001.json','chat_002.json']);
  assert.equal((await connected.open('chat_001.json')).id,another.id);
  assert.equal((await connected.open('chat_002.json')).id,mine.id);
});
test('offline mode preserves local chat creation',async()=>{
  const local=new MemoryLocal(), remote={async list(){throw Error('offline');}};
  const chat=await new ChatStore(local,null,remote).create();
  assert.equal(chat.filename,'chat_001.json');
});
test('same file name with different chat IDs is rejected by merge',async()=>{
  const a=await prepared('chat_001.json','A'),b=await prepared('chat_001.json','B');
  assert.throws(()=>mergeChats(a,b),/Басқа чаттың/);
});
test('GitHub private-only client creates a private repo and sends v3 chats',async()=>{
  const calls=[],base='https://api.github.com';let exists=false;
  const request=async(url,options)=>{
    calls.push({url,options});
    const answer=(data,status=200)=>({ok:status>=200&&status<300,status,async json(){return data;}});
    if(url===base+'/user')return answer({login:'tuze-test'});
    if(url===base+'/repos/tuze-test/Tuze-Private-Chats')return exists?answer({name:'Tuze-Private-Chats',private:true}):answer({},404);
    if(url===base+'/user/repos'&&options.method==='POST'){
      const body=JSON.parse(options.body);assert.equal(body.private,true);exists=true;
      return answer({name:'Tuze-Private-Chats',private:true},201);
    }
    if(url.endsWith('/contents/chats')&&options.method!=='PUT')return answer({},404);
    if(options.method==='PUT')return answer({content:{sha:'abc'}});
    throw Error('Unexpected '+url);
  };
  const gh=githubClient('valid-test-token',request);
  assert.deepEqual(await gh.list(),[]);
  const chat=await prepared('chat_001.json','Сәлем');
  const file={...chat,version:crypto.randomUUID()};
  assert.equal(await gh.put(chat.filename,file),'abc');
  const sent=calls.find(c=>c.options.method==='PUT');
  assert.match(sent.url,/Tuze-Private-Chats\/contents\/chats\/chat_001.json$/);
  assert.deepEqual(JSON.parse(Buffer.from(JSON.parse(sent.options.body).content,'base64').toString()),file);
  assert.equal(sent.options.headers.Authorization,'Bearer valid-test-token');
});
test('a public repo is never allowed to receive plaintext chats',async()=>{
  const calls=[];
  const request=async(url,options)=>{
    calls.push({url,options});
    const data=url.endsWith('/user')?{login:'tuze-test'}:{name:'Tuze-Private-Chats',private:false};
    return {ok:true,status:200,async json(){return data;}};
  };
  const gh=githubClient('valid-test-token',request);
  const file={...(await prepared('chat_001.json','Құпия')),version:crypto.randomUUID()};
  await assert.rejects(gh.put(file.filename,file),/Private емес/);
  assert.equal(calls.filter(c=>c.options.method==='PUT').length,0);
});
test('photo metadata stays intact after sync',async()=>{
  const remote=new MemoryRemote(),store=new ChatStore(new MemoryLocal(),null,remote);
  const chat=await store.create();
  const photo={mime:'image/jpeg',data:'AA==',width:1,height:1};
  await store.append(chat.filename,'user','Бұл не?',photo);await store.syncAll();
  assert.deepEqual((await remote.get(chat.filename)).envelope.messages[0].image,photo);
});
test('generated assistant image stays in its chat and survives GitHub sync',async()=>{
  const remote=new MemoryRemote();
  const laptop=new ChatStore(new MemoryLocal(),null,remote);
  const chat=await laptop.create();
  await laptop.append(chat.filename,'user','Қызыл алма суретін жаса');
  const image={mime:'image/jpeg',data:'AA==',width:512,height:512};
  await laptop.append(chat.filename,'assistant','Жасалған сурет: қызыл алма',image);
  await laptop.syncOne(chat.filename);
  const other=new ChatStore(new MemoryLocal(),null,remote);
  await other.syncAll();
  const restored=await other.open(chat.filename);
  assert.equal(restored.messages[1].role,'assistant');
  assert.deepEqual(restored.messages[1].image,image);
});
test('GitHub reads an image-heavy chat through its blob endpoint after 1 MB',async()=>{
  const file=await prepared('chat_001.json','Large');
  file.version=crypto.randomUUID();
  const sha='a'.repeat(40), requested=[];
  const request=async(url)=>{
    requested.push(url);
    let value;
    if(url.endsWith('/user'))value={login:'tuze-test'};
    else if(url.endsWith('/repos/tuze-test/Tuze-Private-Chats'))value={name:'Tuze-Private-Chats',private:true};
    else if(url.endsWith('/contents/chats/chat_001.json'))value={encoding:'none',content:'',sha};
    else if(url.endsWith('/git/blobs/'+sha))value={encoding:'base64',content:btoa(JSON.stringify(file))};
    else throw new Error(url);
    return {ok:true,status:200,async json(){return value;}};
  };
  const saved=await githubClient('valid-test-token',request).get(file.filename);
  assert.equal(saved.envelope.title,'Large');
  assert.equal(saved.sha,sha);
  assert.ok(requested.some(url=>url.endsWith('/git/blobs/'+sha)));
});

test('message correction saves original text, updates content and survives GitHub sync',async()=>{
  const remote=new MemoryRemote(), local=new MemoryLocal();
  const store=new ChatStore(local,null,remote);
  const chat=await store.create();
  await store.append(chat.filename,'user','салем калайсын');
  await store.append(chat.filename,'assistant','мен жаксымын');
  await store.syncOne(chat.filename);
  const userId=(await store.open(chat.filename)).messages[0].id;
  const assistantId=(await store.open(chat.filename)).messages[1].id;
  await store.editMessage(chat.filename,userId,'салем калайсын','Сәлем, қалайсың?');
  await store.editMessage(chat.filename,assistantId,'мен жаксымын','Мен жақсымын.');
  await store.syncOne(chat.filename);
  const saved=(await store.open(chat.filename)).messages;
  assert.deepEqual(saved.map(x=>x.content),['Сәлем, қалайсың?','Мен жақсымын.']);
  assert.deepEqual(saved.map(x=>x.original_content),['салем калайсын','мен жаксымын']);
  assert.deepEqual((await remote.get(chat.filename)).envelope.messages.map(x=>x.content),saved.map(x=>x.content));
  const other=new ChatStore(new MemoryLocal(),null,remote);
  await other.syncAll();
  assert.equal((await other.open(chat.filename)).messages[1].original_content,'мен жаксымын');
});

test('correction merges with stale unedited GitHub message without conflict',async()=>{
  const remote=new MemoryRemote(), local=new MemoryLocal(), store=new ChatStore(local,null,remote);
  const chat=await store.create();
  await store.append(chat.filename,'user','калысын');
  await store.syncOne(chat.filename);
  const msg=(await store.open(chat.filename)).messages[0];
  await store.editMessage(chat.filename,msg.id,msg.content,'Қалайсың?');
  await store.syncOne(chat.filename);
  assert.equal((await remote.get(chat.filename)).envelope.messages[0].content,'Қалайсың?');
  assert.deepEqual((await store.open(chat.filename)).messages.map(x=>x.content),['Қалайсың?']);
});

test('correction refuses to silently overwrite a message edited elsewhere',async()=>{
  const store=new ChatStore(new MemoryLocal());
  const chat=await store.create();
  await store.append(chat.filename,'user','салем');
  const original=(await store.open(chat.filename)).messages[0];
  await store.editMessage(chat.filename,original.id,'салем','Сәлем!');
  await assert.rejects(store.editMessage(chat.filename,original.id,'салем','Кеш жарық'),/өзгеріп кеткен/);
});

test('large generated code messages remain complete in local chats and private sync',async()=>{
  const local = new MemoryLocal(), remote = new MemoryRemote();
  const store = new ChatStore(local,null,remote), chat=await store.create();
  const longCode='```html filename="index.html"\n'+('console.log("ok");\n'.repeat(700))+'```';
  assert.ok(longCode.length>4000);
  await store.append(chat.filename,'assistant',longCode);
  await store.syncOne(chat.filename);
  assert.equal((await store.open(chat.filename)).messages[0].content,longCode);
  assert.equal((await remote.get(chat.filename)).envelope.messages[0].content,longCode);
});
