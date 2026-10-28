// TUZE Code Workspace — pure helpers, no dependencies and no remote requests.
const extensionFor = {
  html:'html', htm:'html', css:'css', javascript:'js', js:'js', typescript:'ts', ts:'ts',
  jsx:'jsx', tsx:'tsx', json:'json', python:'py', py:'py', bash:'sh', shell:'sh', sh:'sh',
  powershell:'ps1', ps1:'ps1', xml:'xml', svg:'svg', markdown:'md', md:'md',
  java:'java', c:'c', cpp:'cpp', 'c++':'cpp', cs:'cs', csharp:'cs', go:'go', rust:'rs', rs:'rs',
  sql:'sql', php:'php', ruby:'rb', rb:'rb', vue:'vue', svelte:'svelte', text:'txt', txt:'txt'
};
const defaults = {
  html:'index.html', css:'style.css', js:'script.js', ts:'script.ts', jsx:'App.jsx', tsx:'App.tsx',
  py:'main.py', json:'data.json', sh:'run.sh', ps1:'script.ps1', md:'README.md', txt:'notes.txt',
  svg:'image.svg', xml:'data.xml', vue:'App.vue', svelte:'App.svelte'
};
const FENCED = /^[ \t]*```([^\r\n]*)\r?\n([\s\S]*?)^[ \t]*```[ \t]*$/gm;

function fileSafe(name) {
  if (typeof name !== 'string') return '';
  let cleaned = name.trim().replace(/^[`'"*]+|[`'"*,;:]+$/g, '').replace(/\\/g, '/');
  cleaned = cleaned.replace(/^\.\//, '').replace(/^\/+/, '').replace(/\/+/g, '/');
  if (!cleaned || cleaned.length > 120 || cleaned.split('/').some(x => !x || x === '.' || x === '..') ||
      /[<>|?*\x00-\x1f]/.test(cleaned) || cleaned.includes(':')) return '';
  if (!/^[\p{L}\p{N}_ .()\-\/]+\.[a-zA-Z0-9]{1,8}$/u.test(cleaned)) return '';
  return cleaned;
}
function titleFile(before) {
  const line = before.split(/\r?\n/).slice(-3).reverse().find(s => s.trim());
  if (!line) return '';
  const normalized = line.trim().replace(/^#{1,6}\s*/, '').replace(/^[-*]\s*/, '')
    .replace(/^\*\*/, '').replace(/\*\*$/, '').replace(/^(?:file|файл|файлы|filename|файл атауы)\s*[:：]\s*/i, '');
  const stripped = normalized.replace(/^`|`$/g, '').trim().replace(/[:：]\s*$/, '');
  return fileSafe(stripped) || '';
}
function metadata(info, preceding) {
  const trimmed = info.trim();
  const tokens = trimmed.split(/\s+/);
  let language = (tokens[0] || '').toLowerCase();
  let name = '';
  const named = trimmed.match(/(?:^|\s)(?:filename|file|title|path)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s]+))/i);
  if (named) name = fileSafe(named[1] || named[2] || named[3]);
  const colon = language.match(/^([a-z+#]+):(.+)$/i);
  if (colon) { language = colon[1].toLowerCase(); name ||= fileSafe(colon[2]); }
  if (!name && fileSafe(tokens[0] || '')) {
    name = fileSafe(tokens[0]); language = name.split('.').pop().toLowerCase();
  }
  if (!name && tokens[1] && !tokens[1].includes('=')) name = fileSafe(tokens[1]);
  if (!name) name = titleFile(preceding);
  const ext = extensionFor[language] || (name && name.split('.').pop().toLowerCase());
  if (!ext || !Object.values(extensionFor).includes(ext)) return null;
  if (name && name.split('.').pop().toLowerCase() !== ext) name = '';
  return {ext, name};
}
export function extractCodeFiles(text) {
  if (typeof text !== 'string') return {files:[], prose:String(text ?? '')};
  const files = [], used = new Set(), redactions = [];
  FENCED.lastIndex = 0;
  for (const match of text.matchAll(FENCED)) {
    if (files.length >= 24) break;
    const matchStart = match.index;
    const data = metadata(match[1], text.slice(Math.max(0, matchStart - 220), matchStart));
    if (!data || !match[2].trim() || match[2].length > 250_000) continue;
    let name = data.name || defaults[data.ext] || `file.${data.ext}`;
    const basicName = name;
    let suffix = 2;
    while (used.has(name.toLowerCase())) {
      const pos = basicName.lastIndexOf('.');
      name = `${basicName.slice(0,pos)}-${suffix++}${basicName.slice(pos)}`;
    }
    used.add(name.toLowerCase());
    files.push({name, language:data.ext, content:match[2].replace(/\s+$/, '') + '\n'});
    redactions.push([matchStart, matchStart + match[0].length]);
  }
  // A model sometimes sends raw HTML without Markdown fences.
  if (!files.length && /^\s*(?:<!doctype\s+html|<html[\s>])/i.test(text)) {
    files.push({name:'index.html',language:'html',content:text});
    return {files,prose:''};
  }
  let prose = text;
  for (let i = redactions.length - 1; i >= 0; i--) {
    const [start, end] = redactions[i];
    prose = prose.slice(0,start) + prose.slice(end);
  }
  return {files,prose:prose.trim()};
}

function asAsset(files, path, ext) {
  const normalized = path.replace(/^\.\//, '').split(/[?#]/)[0].replace(/\\/g, '/');
  if (/^(?:[a-z]+:|\/\/|\/)/i.test(normalized) || normalized.includes('..')) return null;
  return files.find(f => f.name === normalized && f.language === ext) ||
    files.find(f => f.language === ext && f.name.endsWith('/' + normalized)) || null;
}
function includeCss(html, css) {
  const snippet = `<style>\n${css.replace(/<\/style/gi, '<\\/style')}\n</style>`;
  return /<\/head\s*>/i.test(html) ? html.replace(/<\/head\s*>/i, `${snippet}\n</head>`) : snippet + '\n' + html;
}
function includeJs(html, js) {
  const snippet = `<script>\n${js.replace(/<\/script/gi,'<\\/script')}\n</script>`;
  return /<\/body\s*>/i.test(html) ? html.replace(/<\/body\s*>/i, `${snippet}\n</body>`) : html + '\n' + snippet;
}
export function buildPreviewHtml(files, htmlFileName = '') {
  const entry = files.find(f => f.language === 'html' && f.name === htmlFileName) ||
    files.find(f => f.language === 'html' && /(?:^|\/)index\.html$/i.test(f.name)) ||
    files.find(f => f.language === 'html');
  if (!entry) return null;
  let html = entry.content;
  const used = new Set();
  html = html.replace(/<link\b[^>]*>/gi, tag => {
    if (!/\brel\s*=\s*(?:["']?stylesheet["']?)/i.test(tag)) return tag;
    const href = tag.match(/\bhref\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i);
    if (!href) return tag;
    const asset = asAsset(files, href[1] || href[2] || href[3], 'css');
    if (!asset) return tag;
    used.add(asset.name);
    return `<style>\n${asset.content.replace(/<\/style/gi,'<\\/style')}\n</style>`;
  });
  html = html.replace(/<script\b([^>]*)>\s*<\/script\s*>/gi, (whole, attrs) => {
    const src = attrs.match(/\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i);
    if (!src) return whole;
    const asset = asAsset(files, src[1] || src[2] || src[3], 'js');
    if (!asset) return whole;
    used.add(asset.name);
    const cleaned = attrs.replace(/\s+src\s*=\s*(?:"[^"]+"|'[^']+'|[^\s>]+)/i,'');
    return `<script${cleaned}>\n${asset.content.replace(/<\/script/gi,'<\\/script')}\n</script>`;
  });
  for (const file of files) {
    if (used.has(file.name)) continue;
    if (file.language === 'css') html = includeCss(html, file.content);
    if (file.language === 'js') html = includeJs(html, file.content);
  }
  return html;
}

const encoder = new TextEncoder();
function crc32(bytes) {
  let result = 0xffffffff;
  for (const byte of bytes) {
    result ^= byte;
    for (let i=0;i<8;i++) result = (result >>> 1) ^ (0xedb88320 & -(result & 1));
  }
  return (result ^ 0xffffffff) >>> 0;
}
function header(length) { return new Uint8Array(length); }
function u16(bytes, offset, value) { bytes[offset]=value&255;bytes[offset+1]=(value>>>8)&255; }
function u32(bytes, offset, value) { u16(bytes,offset,value);u16(bytes,offset+2,value>>>16); }
// Stored ZIP (no compression) is deliberately simple and works without CDN or npm.
export function makeCodeZip(files) {
  if (!Array.isArray(files) || files.length > 24 || !files.length) throw new Error('Файлдар жоқ.');
  const parts=[], central=[];
  let cursor = 0;
  for (const file of files) {
    const name = fileSafe(file.name);
    if (!name) throw new Error('Файл атауы жарамсыз.');
    const filename = encoder.encode(name), payload = encoder.encode(file.content);
    if (filename.length > 65535 || payload.length > 1_000_000) throw new Error('Файл өте үлкен.');
    const crc = crc32(payload), local = header(30), directory = header(46);
    u32(local,0,0x04034b50);u16(local,4,20);u16(local,6,0x0800);u16(local,8,0);
    u32(local,14,crc);u32(local,18,payload.length);u32(local,22,payload.length);u16(local,26,filename.length);
    parts.push(local,filename,payload);
    u32(directory,0,0x02014b50);u16(directory,4,20);u16(directory,6,20);
    u16(directory,8,0x0800);u32(directory,16,crc);u32(directory,20,payload.length);
    u32(directory,24,payload.length);u16(directory,28,filename.length);u32(directory,42,cursor);
    central.push(directory,filename);
    cursor += local.length + filename.length + payload.length;
  }
  let centralSize = 0;
  for (const byteArray of central) centralSize += byteArray.length;
  const footer=header(22);
  u32(footer,0,0x06054b50);u16(footer,8,files.length);u16(footer,10,files.length);
  u32(footer,12,centralSize);u32(footer,16,cursor);
  return new Blob([...parts,...central,footer],{type:'application/zip'});
}
