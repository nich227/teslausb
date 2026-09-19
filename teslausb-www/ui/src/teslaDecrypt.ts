// Decrypts the clips a Tesla writes with "Encrypt Dashcam Recordings" turned on.
//
// This reproduces what dashcam.tesla.com does in the browser, and nothing more. The files
// keep their .mp4 names but are containers: two 4 KiB header pages, then the video encrypted
// with AES-128-CBC in 4 KiB pages. The second header page carries the ownership metadata Tesla
// needs to hand back the per-file key: a key id, the car's public key, its VIN, a timestamp
// and the wrapped key. The browser posts those to Tesla, gets the AES key, and decrypts
// locally. The video never leaves the browser, and neither does the key; the device serving
// the file sees only ciphertext.
//
// Layout, as observed in real 2026.20 files and confirmed against Tesla's own viewer bundle:
//
//   0x0000  8   plaintext size, big-endian
//   0x0004  16  file id, used as the API item id
//   0x0014  4   metadata offset, 4096 for a real file
//   0x1000  4   key_id, big-endian
//   0x1004  65  public key, uncompressed EC point beginning 0x04
//   0x1045  17  VIN, ASCII
//   0x1056  8   timestamp, big-endian
//   0x105e  44  wrapped key
//   0x2000+     ciphertext in 4096-byte pages
//
// Each page's IV is MD5(MD5(key) + ascii(page number), zero padded to 32 bytes), which is the
// eCryptfs convention. WebCrypto has no MD5, so a small one is included below.

export const TESLA_DASHCAM_URL = 'https://dashcam.tesla.com';
// Tesla's endpoint sends no CORS headers, so the browser cannot call it from this origin.
// nginx on the device forwards this path to it, unchanged, making it same-origin.
export const DECRYPT_URL = 'tesla/decrypt';
const PAGE = 4096;
const META_OFFSET = 0x1000;
const CIPHERTEXT_OFFSET = 0x2000;

export interface ClipHeader {
  id: string;
  vin: string;
  key_id: number;
  timestamp: number;
  wrapped_key: string;
  public_key: string;
  plaintextSize: number;
}

const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));

/** True when the bytes look like a Tesla encrypted container rather than a plain MP4. */
export function isEncryptedContainer(head: Uint8Array): boolean {
  if (head.length < META_OFFSET + 4) return false;
  const view = new DataView(head.buffer, head.byteOffset, head.byteLength);
  if (view.getUint32(0x14) !== META_OFFSET) return false;
  // a plain MP4 begins with an ftyp box a few bytes in; a container has a size then an id
  return view.getUint32(META_OFFSET) !== 0;
}

/** Reads the ownership metadata Tesla needs to return the file key. */
export function readClipHeader(head: Uint8Array): ClipHeader {
  if (head.length < CIPHERTEXT_OFFSET) throw new Error('file too short to be an encrypted clip');
  const view = new DataView(head.buffer, head.byteOffset, head.byteLength);
  const plaintextSize = Number(view.getBigUint64(0));
  const idBytes = head.subarray(4, 20);
  const h = hex(idBytes);
  const id = `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  const publicKey = head.subarray(META_OFFSET + 4, META_OFFSET + 4 + 65);
  if (publicKey[0] !== 0x04) throw new Error('not a Tesla encrypted clip (public key)');
  const vin = new TextDecoder('ascii')
    .decode(head.subarray(META_OFFSET + 69, META_OFFSET + 86))
    .replace(/\0+$/, '');
  if (vin.length !== 17) throw new Error('not a Tesla encrypted clip (VIN)');
  return {
    id,
    vin,
    key_id: view.getUint32(META_OFFSET),
    timestamp: Number(view.getBigUint64(META_OFFSET + 86)),
    wrapped_key: b64(head.subarray(META_OFFSET + 94, META_OFFSET + 138)),
    public_key: b64(publicKey),
    plaintextSize,
  };
}

/** Asks Tesla for the per-file AES key. The token is the one dashcam.tesla.com uses. */
export async function fetchClipKey(header: ClipHeader, token: string): Promise<Uint8Array> {
  const { plaintextSize: _, ...item } = header;
  const resp = await fetch(DECRYPT_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ items: [item] }),
  });
  if (resp.status === 401 || resp.status === 403) throw new TokenError();
  if (!resp.ok) throw new Error(`Tesla returned ${resp.status}`);
  const data = (await resp.json()) as { results?: { id: string; key?: string; error?: string }[] };
  const r = data.results?.[0];
  if (!r || r.error || !r.key) throw new Error(r?.error || 'Tesla returned no key for this clip');
  return Uint8Array.from(atob(r.key), (c) => c.charCodeAt(0));
}

export class TokenError extends Error {
  constructor() {
    super('Tesla did not accept the token. It may have expired.');
    this.name = 'TokenError';
  }
}

/** Decrypts a whole container into MP4 bytes, given the key Tesla returned. */
export async function decryptClip(file: Uint8Array, key: Uint8Array): Promise<Uint8Array> {
  const keyBytes = new Uint8Array(key); // a fresh ArrayBuffer-backed copy, which WebCrypto's types require
  const header = readClipHeader(file);
  const cryptoKey = await crypto.subtle.importKey('raw', keyBytes, { name: 'AES-CBC' }, false, [
    'encrypt',
    'decrypt',
  ]);
  const rootIv = md5(keyBytes);
  const out = new Uint8Array(header.plaintextSize);
  let written = 0;
  let page = 0;
  for (let off = CIPHERTEXT_OFFSET; written < header.plaintextSize; off += PAGE) {
    const cipherPage = file.subarray(off, off + PAGE);
    if (cipherPage.length !== PAGE) throw new Error('truncated encrypted clip');
    const ivMaterial = new Uint8Array(32);
    ivMaterial.set(rootIv);
    ivMaterial.set(new TextEncoder().encode(String(page)), 16);
    const iv = md5(ivMaterial);
    const plain = await decryptPage(cipherPage, cryptoKey, iv);
    const take = Math.min(PAGE, header.plaintextSize - written);
    out.set(plain.subarray(0, take), written);
    written += take;
    page++;
  }
  return out;
}

// WebCrypto's AES-CBC only decrypts PKCS#7-padded data, and an eCryptfs page is a bare 4096
// bytes. Append one block that will decrypt to sixteen 0x10 bytes, which is what valid padding
// looks like, by encrypting that block with the page's final ciphertext block as its IV. Then
// WebCrypto accepts the page and strips the padding again, leaving the 4096 real bytes.
async function decryptPage(
  cipherPage: Uint8Array,
  key: CryptoKey,
  iv: Uint8Array,
): Promise<Uint8Array> {
  // Copies rather than subarray views: WebCrypto's types want plain ArrayBuffer-backed data,
  // and a view over the file's buffer does not satisfy them.
  const lastBlock = new Uint8Array(cipherPage.subarray(PAGE - 16));
  const padBlock = new Uint8Array(16).fill(16);
  // encrypt() appends a padding block of its own, so only the first block is wanted
  const enc = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-CBC', iv: lastBlock }, key, padBlock),
  );
  const padded = new Uint8Array(PAGE + 16);
  padded.set(cipherPage);
  padded.set(enc.subarray(0, 16), PAGE);
  return new Uint8Array(
    await crypto.subtle.decrypt({ name: 'AES-CBC', iv: new Uint8Array(iv) }, key, padded),
  );
}

// MD5, needed only for the eCryptfs IV derivation. WebCrypto deliberately omits it.
export function md5(input: Uint8Array): Uint8Array {
  const K = new Int32Array(64);
  const S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
  for (let i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) | 0;
  const len = input.length;
  const padLen = (((len + 8) >>> 6) << 6) + 64;
  const buf = new Uint8Array(padLen);
  buf.set(input);
  buf[len] = 0x80;
  const dv = new DataView(buf.buffer);
  dv.setUint32(padLen - 8, (len * 8) >>> 0, true);
  dv.setUint32(padLen - 4, Math.floor((len * 8) / 2 ** 32), true);
  let a0 = 0x67452301,
    b0 = 0xefcdab89 | 0,
    c0 = 0x98badcfe | 0,
    d0 = 0x10325476;
  const rotl = (x: number, c: number) => (x << c) | (x >>> (32 - c));
  for (let off = 0; off < padLen; off += 64) {
    const M = new Int32Array(16);
    for (let i = 0; i < 16; i++) M[i] = dv.getInt32(off + i * 4, true);
    let A = a0,
      B = b0,
      C = c0,
      D = d0;
    for (let i = 0; i < 64; i++) {
      let F: number, g: number;
      if (i < 16) {
        F = (B & C) | (~B & D);
        g = i;
      } else if (i < 32) {
        F = (D & B) | (~D & C);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        F = B ^ C ^ D;
        g = (3 * i + 5) % 16;
      } else {
        F = C ^ (B | ~D);
        g = (7 * i) % 16;
      }
      F = (F + A + K[i] + M[g]) | 0;
      A = D;
      D = C;
      C = B;
      B = (B + rotl(F, S[(i >> 4) * 4 + (i % 4)])) | 0;
    }
    a0 = (a0 + A) | 0;
    b0 = (b0 + B) | 0;
    c0 = (c0 + C) | 0;
    d0 = (d0 + D) | 0;
  }
  const out = new Uint8Array(16);
  const ov = new DataView(out.buffer);
  ov.setInt32(0, a0, true);
  ov.setInt32(4, b0, true);
  ov.setInt32(8, c0, true);
  ov.setInt32(12, d0, true);
  return out;
}
