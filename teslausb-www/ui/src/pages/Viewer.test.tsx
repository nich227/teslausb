import { describe, it, expect } from 'vitest';
import { splitClipPath, groupLabel, isEncryptedGroup } from './Viewer';

// Recent Tesla software writes a second tree under EncryptedClips/, one level deeper than
// the classic folders. The viewer used to destructure exactly three path parts, so every
// encrypted clip fell out of the list: the event folder landed in the filename slot and
// failed the .mp4 check. These pin the parsing for both shapes.
describe('splitClipPath', () => {
  it('splits a classic three-part path', () => {
    expect(splitClipPath('SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4')).toEqual({
      grp: 'SentryClips',
      seq: '2026-09-18_11-00-00',
      filename: '2026-09-18_10-59-00-front.mp4',
    });
  });

  it('keeps the encrypted prefix as part of the group', () => {
    expect(
      splitClipPath('EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4'),
    ).toEqual({
      grp: 'EncryptedClips/SentryClips',
      seq: '2026-09-18_11-00-00',
      filename: '2026-09-18_10-59-00-front.mp4',
    });
  });

  it('so the group rebuilds the same URL the file is served at', () => {
    const s = splitClipPath('EncryptedClips/SavedClips/e1/clip.mp4')!;
    expect(`TeslaCam/${s.grp}/${s.seq}/${s.filename}`).toBe(
      'TeslaCam/EncryptedClips/SavedClips/e1/clip.mp4',
    );
  });

  it('rejects lines with nothing to play', () => {
    expect(splitClipPath('SentryClips')).toBeNull();
    expect(splitClipPath('SentryClips/2026-09-18_11-00-00')).toBeNull();
  });
});

describe('groupLabel', () => {
  it('leaves classic groups alone', () => {
    expect(groupLabel('SentryClips')).toBe('SentryClips');
  });

  it('marks encrypted groups without hiding which category they are', () => {
    expect(groupLabel('EncryptedClips/SentryClips')).toBe('SentryClips (encrypted)');
  });
});

describe('isEncryptedGroup', () => {
  // Encrypted files keep the .mp4 name but are AES containers a browser cannot play, so
  // the viewer has to know which groups to warn about rather than show a blank player.
  it('recognises the encrypted tree', () => {
    expect(isEncryptedGroup('EncryptedClips/SentryClips')).toBe(true);
  });
  it('and not the classic one', () => {
    expect(isEncryptedGroup('SentryClips')).toBe(false);
  });
});
