const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const FILE_RE = /^chat_\d{3,}\.json$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const KDF_ITERATIONS = 600_000;

function b64(bytes) {
  let text = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    text += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(text);
}

function unb64(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) {
    throw new Error('Шифрланған файлдың base64 пішімі жарамсыз.');
  }
  return Uint8Array.from(atob(value), char => char.charCodeAt(0));
}

function validateChat(chat, filename) {
  if (!FILE_RE.test(filename) || !chat || chat.schema_version !== 2 ||
      !UUID_RE.test(chat.id) || chat.filename !== filename ||
      typeof chat.title !== 'string' || typeof chat.created_at !== 'string' ||
      typeof chat.updated_at !== 'string' || !Array.isArray(chat.messages)) {
    throw new Error('Чаттың идентификаторы немесе файлы сәйкес келмейді.');
  }
  const seen = new Set();
  for (const message of chat.messages) {
    if (!message || !UUID_RE.test(message.id) || seen.has(message.id) ||
        !['user', 'assistant'].includes(message.role) ||
        typeof message.content !== 'string' || typeof message.created_at !== 'string') {
      throw new Error('Чаттағы хабарлама жарамсыз.');
    }
    seen.add(message.id);
  }
  return chat;
}

async function keyFor(passphrase, salt, usage) {
  if (typeof passphrase !== 'string' || passphrase.length < 12) {
    throw new Error('Кілтсөз кемінде 12 таңба болсын. Оны жоғалтпаңыз.');
  }
  const material = await crypto.subtle.importKey('raw', encoder.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: KDF_ITERATIONS, hash: 'SHA-256' },
    material, { name: 'AES-GCM', length: 256 }, false, [usage],
  );
}

function aad(filename, id) {
  return encoder.encode(`TUZE:chat:v2:${filename}:${id}`);
}

export async function encryptChat(chat, passphrase) {
  validateChat(chat, chat.filename);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await keyFor(passphrase, salt, 'encrypt');
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, additionalData: aad(chat.filename, chat.id), tagLength: 128 },
    key, encoder.encode(JSON.stringify(chat)),
  ));
  return {
    schema_version: 2, id: chat.id, filename: chat.filename, updated_at: chat.updated_at,
    version: crypto.randomUUID(),
    encryption: { algorithm: 'AES-256-GCM', kdf: 'PBKDF2-HMAC-SHA256',
      iterations: KDF_ITERATIONS, salt: b64(salt), nonce: b64(nonce), ciphertext: b64(ciphertext) },
  };
}

export async function decryptChat(envelope, passphrase, filename) {
  if (!envelope || envelope.schema_version !== 2 || !FILE_RE.test(filename) ||
      envelope.filename !== filename || !UUID_RE.test(envelope.id) ||
      !envelope.encryption || envelope.encryption.algorithm !== 'AES-256-GCM' ||
      envelope.encryption.kdf !== 'PBKDF2-HMAC-SHA256' ||
      envelope.encryption.iterations !== KDF_ITERATIONS) {
    throw new Error('Шифрланған файлдың атауы не пішімі сәйкес келмейді.');
  }
  const salt = unb64(envelope.encryption.salt);
  const nonce = unb64(envelope.encryption.nonce);
  const ciphertext = unb64(envelope.encryption.ciphertext);
  if (salt.length !== 16 || nonce.length !== 12 || ciphertext.length < 17) {
    throw new Error('Шифрланған файл толық емес.');
  }
  const key = await keyFor(passphrase, salt, 'decrypt');
  let chat;
  try {
    const clear = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce, additionalData: aad(filename, envelope.id), tagLength: 128 },
      key, ciphertext,
    );
    chat = JSON.parse(decoder.decode(clear));
  } catch {
    throw new Error('Кілтсөз қате немесе чат файлы бүлінген. Ештеңе жазылмады.');
  }
  validateChat(chat, filename);
  if (chat.id !== envelope.id || chat.updated_at !== envelope.updated_at) {
    throw new Error('Чат метадеректері сәйкес келмейді. Ештеңе жазылмады.');
  }
  return chat;
}

export function newChat(filename) {
  if (!FILE_RE.test(filename)) throw new Error('Файл атауы жарамсыз.');
  const now = new Date().toISOString();
  return { schema_version: 2, id: crypto.randomUUID(), filename,
    title: 'Жаңа чат', created_at: now, updated_at: now, messages: [] };
}

export function nextFilename(filenames) {
  let max = 0;
  for (const filename of filenames) {
    if (FILE_RE.test(filename)) max = Math.max(max, Number(filename.slice(5, -5)));
  }
  return `chat_${String(max + 1).padStart(3, '0')}.json`;
}

export { FILE_RE };
