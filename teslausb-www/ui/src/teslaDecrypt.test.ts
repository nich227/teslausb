import { describe, it, expect } from 'vitest';
import { createHash, createCipheriv, randomBytes } from 'node:crypto';
import { webcrypto } from 'node:crypto';
import { md5, readClipHeader, decryptClip, isEncryptedContainer } from './teslaDecrypt';

// The only way to be sure the decryption is right without a real Tesla file is to build a
// container exactly the way the car does and get the plaintext back. Node's crypto stands in
// for the car here: it encrypts with the same AES-128-CBC pages and the same eCryptfs IV
// derivation that the published analysis of real 2026.20 files describes, and the module
// under test has to undo it byte for byte.

const PAGE = 4096;
const key = randomBytes(16);

function nodeMd5(b: Uint8Array): Uint8Array {
  return new Uint8Array(createHash('md5').update(b).digest());
}

function pageIv(pageNo: number): Uint8Array {
  const material = new Uint8Array(32);
  material.set(nodeMd5(key));
  material.set(new TextEncoder().encode(String(pageNo)), 16);
  return nodeMd5(material);
}

function buildContainer(plaintext: Uint8Array): Uint8Array {
  const pages = Math.ceil(plaintext.length / PAGE);
  const file = new Uint8Array(0x2000 + pages * PAGE);
  const view = new DataView(file.buffer);
  // The size (8 bytes at 0) and the id (16 bytes at 4) overlap by four bytes in the real
  // layout, so the id's first four bytes are the low half of the size. Write the size last.
  file.set(randomBytes(16), 4); // file id
  view.setBigUint64(0, BigInt(plaintext.length));
  view.setUint32(0x14, 0x1000); // metadata offset
  view.setUint32(0x1000, 7); // key_id
  const pub = new Uint8Array(65);
  pub[0] = 0x04;
  pub.set(randomBytes(64), 1);
  file.set(pub, 0x1004);
  file.set(new TextEncoder().encode('5YJ3E1EA7KF000001'), 0x1045);
  view.setBigUint64(0x1056, BigInt(1758300000));
  file.set(randomBytes(44), 0x105e);
  for (let p = 0; p < pages; p++) {
    const chunk = new Uint8Array(PAGE);
    chunk.set(plaintext.subarray(p * PAGE, (p + 1) * PAGE));
    const c = createCipheriv('aes-128-cbc', key, pageIv(p));
    c.setAutoPadding(false);
    const enc = Buffer.concat([c.update(chunk), c.final()]);
    file.set(enc, 0x2000 + p * PAGE);
  }
  return file;
}

describe('md5', () => {
  it('matches a reference implementation on the inputs the IV derivation uses', () => {
    for (const input of [new Uint8Array(0), key, new Uint8Array(32), randomBytes(100)]) {
      expect(Buffer.from(md5(input)).toString('hex')).toBe(
        Buffer.from(nodeMd5(input)).toString('hex'),
      );
    }
  });
});

describe('readClipHeader', () => {
  it('reads the ownership metadata Tesla needs for the key request', () => {
    const file = buildContainer(new Uint8Array(100));
    const h = readClipHeader(file);
    expect(h.vin).toBe('5YJ3E1EA7KF000001');
    expect(h.key_id).toBe(7);
    expect(h.timestamp).toBe(1758300000);
    expect(h.plaintextSize).toBe(100);
    expect(h.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    expect(atob(h.public_key).charCodeAt(0)).toBe(0x04);
    expect(atob(h.wrapped_key).length).toBe(44);
  });

  it('refuses a plain MP4', () => {
    const mp4 = new Uint8Array(0x2000);
    mp4.set(new TextEncoder().encode('....ftypisom'), 0);
    expect(isEncryptedContainer(mp4)).toBe(false);
    expect(() => readClipHeader(mp4)).toThrow();
  });

  it('recognises a container', () => {
    expect(isEncryptedContainer(buildContainer(new Uint8Array(10)))).toBe(true);
  });
});

describe('decryptClip', () => {
  // vitest's jsdom environment lacks crypto.subtle; use Node's WebCrypto, which is the same API
  Object.defineProperty(globalThis, 'crypto', { value: webcrypto, configurable: true });

  it('recovers a clip that spans several pages, including a partial final page', async () => {
    const plaintext = randomBytes(PAGE * 2 + 1234);
    const out = await decryptClip(buildContainer(plaintext), key);
    expect(out.length).toBe(plaintext.length);
    expect(Buffer.from(out).equals(plaintext)).toBe(true);
  });

  it('recovers a clip that is exactly one page', async () => {
    const plaintext = randomBytes(PAGE);
    const out = await decryptClip(buildContainer(plaintext), key);
    expect(Buffer.from(out).equals(plaintext)).toBe(true);
  });

  it('fails loudly on a truncated file rather than returning garbage', async () => {
    const file = buildContainer(randomBytes(PAGE * 2));
    await expect(decryptClip(file.subarray(0, file.length - 100), key)).rejects.toThrow(
      /truncated/,
    );
  });

  it('produces different bytes with the wrong key, so a bad key cannot pass silently', async () => {
    const plaintext = randomBytes(PAGE);
    const out = await decryptClip(buildContainer(plaintext), randomBytes(16));
    expect(Buffer.from(out).equals(plaintext)).toBe(false);
  });
});
