import {test} from 'node:test';
import assert from 'node:assert/strict';
import {extractCodeFiles,buildPreviewHtml,makeCodeZip} from '../app/code-files.mjs';
const demo=`Міне дайын шағын сайт:\n\n\`\`\`html filename="index.html"\n<!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body><button id="btn">OK</button><script src="script.js"></script></body></html>\n\`\`\`\n\n\`\`\`css filename="style.css"\nbody { background: rgb(1,2,3); }\n\`\`\`\n\n\`\`\`javascript filename="script.js"\ndocument.getElementById('btn').onclick = () => { document.querySelector('#btn').textContent = 'Болды!'; };\n\`\`\`\n`;
test('extracts three named files while keeping Kazakh explanation',()=>{
  const {files,prose}=extractCodeFiles(demo);
  assert.deepEqual(files.map(f=>f.name),['index.html','style.css','script.js']);
  assert.match(prose,/шағын сайт/);
  assert.doesNotMatch(prose,/<!doctype/);
});
test('combines CSS and JavaScript relative file references without external fetch',()=>{
  const {files}=extractCodeFiles(demo);
  const html=buildPreviewHtml(files);
  assert.match(html,/body \{ background: rgb\(1,2,3\)/);
  assert.match(html,/document\.getElementById\('btn'\)/);
  assert.doesNotMatch(html,/src="script.js"/);
  assert.doesNotMatch(html,/href="style.css"/);
});
test('guesses filenames from generic code fences and makes collisions distinct',()=>{
  const {files}=extractCodeFiles('```html\n<h1>One</h1>\n```\n```html\n<h1>Two</h1>\n```\n```python\nprint(1)\n```');
  assert.deepEqual(files.map(f=>f.name),['index.html','index-2.html','main.py']);
});
test('uses heading based filenames and prevents path traversal',()=>{
  const {files}=extractCodeFiles('### `src/app.js`\n```js\nconsole.log("ok")\n```\n```html filename="../../leak.html"\n<h1>test</h1>\n```');
  assert.deepEqual(files.map(f=>f.name),['src/app.js','index.html']);
});
test('supports standalone HTML without fences and non-previewable Python',()=>{
  assert.equal(extractCodeFiles('<!doctype html><h1>hello</h1>').files[0].name,'index.html');
  assert.equal(buildPreviewHtml(extractCodeFiles('```python\nprint("hi")\n```').files),null);
});
test('ZIP has a valid end-of-central-directory record and all three entries',async()=>{
  const {files}=extractCodeFiles(demo);
  const zipped=new Uint8Array(await makeCodeZip(files).arrayBuffer());
  const view=new DataView(zipped.buffer);
  assert.equal(view.getUint32(0,true),0x04034b50);
  assert.equal(view.getUint32(zipped.length-22,true),0x06054b50);
  assert.equal(view.getUint16(zipped.length-12,true),3);
  assert.equal(view.getUint16(zipped.length-2,true),0); // ZIP comment length
});
