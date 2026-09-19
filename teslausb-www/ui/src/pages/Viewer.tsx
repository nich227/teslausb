import { useEffect, useMemo, useRef, useState, useCallback } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Select, { SelectProps } from '@cloudscape-design/components/select';
import Box from '@cloudscape-design/components/box';
import Alert from '@cloudscape-design/components/alert';
import Button from '@cloudscape-design/components/button';
import * as api from '../api';
import TeslaTokenModal, { getTeslaToken, setTeslaToken } from '../components/TeslaTokenModal';
import { decryptClip, fetchClipKey, readClipHeader, TokenError } from '../teslaDecrypt';
import './viewer.css';

const CAMS = ['front', 'left_repeater', 'right_repeater', 'back'] as const;
type Cam = (typeof CAMS)[number] | 'left_pillar' | 'right_pillar';
type Segment = { ts: string; cameras: Partial<Record<Cam, string>> };
type Groups = Record<string, Record<string, Segment[]>>;

// Recent Tesla software also writes under EncryptedClips/, one level deeper. The group is
// the whole path prefix, so it drops straight into the TeslaCam/<group>/<seq>/<file> URLs
// below, and only the label shown to the user is prettied up.
const GROUP_ORDER = [
  'RecentClips',
  'SavedClips',
  'SentryClips',
  'EncryptedClips/RecentClips',
  'EncryptedClips/SavedClips',
  'EncryptedClips/SentryClips',
];
export const isEncryptedGroup = (g: string) => g.startsWith('EncryptedClips/');
export const groupLabel = (g: string) =>
  isEncryptedGroup(g) ? `${g.slice('EncryptedClips/'.length)} (encrypted)` : g;

// Splits a videolist line into its group, event and file. The last two parts are always
// <seq>/<file>; whatever precedes them is the group, which is one level for the classic
// folders and two for the encrypted ones. Returns null for anything too short to be a clip.
export function splitClipPath(line: string): { grp: string; seq: string; filename: string } | null {
  const parts = line.split('/');
  if (parts.length < 3) return null;
  return {
    filename: parts[parts.length - 1],
    seq: parts[parts.length - 2],
    grp: parts.slice(0, -2).join('/'),
  };
}
const SEG_MS = 60000;

// Bootstrap Icons (MIT) inlined as SVG paths so we don't ship a webfont to the Pi.
const ICON_PATHS: Record<string, string[]> = {
  'camera-video': [
    'M0 5a2 2 0 0 1 2-2h7.5a2 2 0 0 1 1.983 1.738l3.11-1.382A1 1 0 0 1 16 4.269v7.462a1 1 0 0 1-1.406.913l-3.111-1.382A2 2 0 0 1 9.5 13H2a2 2 0 0 1-2-2V5zm11.5 5.175 3.5 1.556V4.269l-3.5 1.556v4.35zM2 4a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h7.5a1 1 0 0 0 1-1V5a1 1 0 0 0-1-1H2z',
  ],
  'chevron-left': [
    'M11.354 1.646a.5.5 0 0 1 0 .708L5.707 8l5.647 5.646a.5.5 0 0 1-.708.708l-6-6a.5.5 0 0 1 0-.708l6-6a.5.5 0 0 1 .708 0z',
  ],
  'chevron-right': [
    'M4.646 1.646a.5.5 0 0 1 .708 0l6 6a.5.5 0 0 1 0 .708l-6 6a.5.5 0 0 1-.708-.708L10.293 8 4.646 2.354a.5.5 0 0 1 0-.708z',
  ],
  ccw: [
    'M8 3a5 5 0 1 1-4.546 2.914.5.5 0 0 0-.908-.417A6 6 0 1 0 8 2v1z',
    'M8 4.466V.534a.25.25 0 0 0-.41-.192L5.23 2.308a.25.25 0 0 0 0 .384l2.36 1.966A.25.25 0 0 0 8 4.466z',
  ],
  cw: [
    'M8 3a5 5 0 1 0 4.546 2.914.5.5 0 0 1 .908-.417A6 6 0 1 1 8 2v1z',
    'M8 4.466V.534a.25.25 0 0 1 .41-.192l2.36 1.966c.12.1.12.284 0 .384L8.41 4.658A.25.25 0 0 1 8 4.466z',
  ],
  play: [
    'M11.596 8.697l-6.363 3.692C4.713 12.69 4 12.345 4 11.692V4.308c0-.653.713-.998 1.233-.696l6.363 3.692a.802.802 0 0 1 0 1.393z',
  ],
  pause: [
    'M5.5 3.5A1.5 1.5 0 0 1 7 5v6a1.5 1.5 0 0 1-3 0V5a1.5 1.5 0 0 1 1.5-1.5zm5 0A1.5 1.5 0 0 1 12 5v6a1.5 1.5 0 0 1-3 0V5a1.5 1.5 0 0 1 1.5-1.5z',
  ],
  download: [
    'M.5 9.9a.5.5 0 0 1 .5.5v2.5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2.5a.5.5 0 0 1 1 0v2.5a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-2.5a.5.5 0 0 1 .5-.5z',
    'M7.646 11.854a.5.5 0 0 0 .708 0l3-3a.5.5 0 0 0-.708-.708L8.5 10.293V1.5a.5.5 0 0 0-1 0v8.793L5.354 8.146a.5.5 0 1 0-.708.708l3 3z',
  ],
};

function Ico({ n }: { n: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      width="1em"
      height="1em"
      fill="currentColor"
      style={{ display: 'block' }}
      aria-hidden="true"
    >
      {(ICON_PATHS[n] || []).map((d, i) => (
        <path key={i} d={d} />
      ))}
    </svg>
  );
}

function detectCam(filename: string): Cam | null {
  if (filename.includes('left_repeater')) return 'left_repeater';
  if (filename.includes('right_repeater')) return 'right_repeater';
  if (filename.includes('left_pillar')) return 'left_pillar';
  if (filename.includes('right_pillar')) return 'right_pillar';
  if (filename.includes('front')) return 'front';
  if (filename.includes('back')) return 'back';
  return null;
}

// "2024-01-15_13-30-00" -> Date (wall-clock from the recording filename)
function segStartDate(ts: string): Date | null {
  const [d, t] = ts.split('_');
  if (!d || !t) return null;
  const date = new Date(`${d}T${t.replace(/-/g, ':')}`);
  return isNaN(date.getTime()) ? null : date;
}

function formatDateTime(date: Date): string {
  return date.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
    hour12: true,
  });
}

const LAYOUTS = [
  { value: 'layout-standard', label: 'Standard' },
  { value: 'layout-mirror', label: 'Sides on top' },
  { value: 'layout-stack', label: 'Stacked (mobile)' },
];

export default function Viewer() {
  const [groups, setGroups] = useState<Groups>({});
  const [jsonBySeq, setJsonBySeq] = useState<Record<string, string>>({});
  const [group, setGroup] = useState<string>('');
  const [seqName, setSeqName] = useState<string>('');
  const [segIdx, setSegIdx] = useState(0);
  const [posMs, setPosMs] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [buffering, setBuffering] = useState(false);
  const [controlsVisible, setControlsVisible] = useState(true);
  const [layout, setLayout] = useState('layout-standard');
  const [mapUrl, setMapUrl] = useState('');
  const [loading, setLoading] = useState(true);
  // Encrypted clips: the token from dashcam.tesla.com, the modal that collects it, and any
  // reason decryption stopped. Decrypted video lives in blob URLs that are revoked on change.
  const [teslaToken, setTeslaTokenState] = useState(getTeslaToken);
  const [tokenModal, setTokenModal] = useState<{ open: boolean; expired: boolean }>({
    open: false,
    expired: false,
  });
  const [decryptError, setDecryptError] = useState<string | null>(null);
  const blobUrls = useRef<Record<string, string>>({});

  const videoRefs = useRef<Record<string, HTMLVideoElement | null>>({});
  const mapDivRef = useRef<HTMLDivElement>(null);
  const seekRef = useRef<HTMLDivElement | null>(null);
  const fillRef = useRef<HTMLDivElement | null>(null);
  const handleRef = useRef<HTMLDivElement | null>(null);
  const scrubbing = useRef(false);
  const segIdxRef = useRef(0);
  const durationRef = useRef(0);
  const hideTimer = useRef<number>();

  useEffect(() => {
    (async () => {
      const lines = await api.getVideoList();
      const g: Groups = {};
      const jsons: Record<string, string> = {};
      const segMap: Record<string, Record<string, Map<string, Segment>>> = {};
      for (const line of lines) {
        const split = splitClipPath(line);
        if (!split) continue;
        const { grp, seq, filename } = split;
        if (!filename || filename.includes('~')) continue;
        if (filename.includes('json')) {
          jsons[`${grp}/${seq}`] = `${grp}/${seq}/${filename}`;
          continue;
        }
        if (!filename.endsWith('.mp4') || filename === 'event.mp4') continue;
        const cam = detectCam(filename);
        if (!cam) continue;
        const ts = filename.substring(0, 19);
        (segMap[grp] ??= {})[seq] ??= new Map<string, Segment>();
        let seg = segMap[grp][seq].get(ts);
        if (!seg) {
          seg = { ts, cameras: {} };
          segMap[grp][seq].set(ts, seg);
        }
        seg.cameras[cam] = filename;
      }
      for (const grp of Object.keys(segMap)) {
        g[grp] = {};
        for (const seq of Object.keys(segMap[grp]))
          g[grp][seq] = Array.from(segMap[grp][seq].values()).sort((a, b) =>
            a.ts.localeCompare(b.ts),
          );
      }
      setGroups(g);
      setJsonBySeq(jsons);
      const firstGroup =
        GROUP_ORDER.find((x) => g[x] && Object.keys(g[x]).length) || Object.keys(g)[0] || '';
      setGroup(firstGroup);
      if (firstGroup) {
        const seqs = Object.keys(g[firstGroup]).sort().reverse();
        setSeqName(seqs[0] || '');
      }
      setLoading(false);
    })().catch(() => setLoading(false));
  }, []);

  const segments: Segment[] = useMemo(
    () => (group && seqName && groups[group]?.[seqName]) || [],
    [groups, group, seqName],
  );
  const durationMs = segments.length * SEG_MS;
  const current = segments[segIdx];

  useEffect(() => {
    segIdxRef.current = segIdx;
  }, [segIdx]);
  useEffect(() => {
    durationRef.current = durationMs;
  }, [durationMs]);

  const masterCam = useCallback((): HTMLVideoElement | null => {
    if (!current) return null;
    for (const c of ['front', 'back', 'left_repeater', 'right_repeater'])
      if (current.cameras[c as Cam] && videoRefs.current[c]) return videoRefs.current[c]!;
    return null;
  }, [current]);
  const masterRef = useRef(masterCam);
  useEffect(() => {
    masterRef.current = masterCam;
  }, [masterCam]);

  // Paint the red fill + handle directly (no React re-render) for smooth motion.
  const paintBar = (pct: number) => {
    const p = `${Math.min(100, Math.max(0, pct))}%`;
    if (fillRef.current) fillRef.current.style.width = p;
    if (handleRef.current) handleRef.current.style.left = p;
  };

  // rAF loop drives the scrubber smoothly from the master video's currentTime.
  useEffect(() => {
    let raf = 0;
    const tick = () => {
      if (!scrubbing.current) {
        const v = masterRef.current();
        const dur = durationRef.current;
        if (v && dur > 0)
          paintBar(((segIdxRef.current * SEG_MS + v.currentTime * 1000) / dur) * 100);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  // Load a segment's sources. Plain clips are streamed straight from the device. Encrypted
  // ones are fetched whole, decrypted here in the browser with the key Tesla returns for that
  // file, and played from a blob URL; the device only ever serves ciphertext.
  useEffect(() => {
    if (!current) return;
    const encrypted = isEncryptedGroup(group);
    if (encrypted && !teslaToken) return;
    let cancelled = false;
    for (const c of CAMS) {
      const v = videoRefs.current[c];
      if (!v) continue;
      const fn = current.cameras[c];
      if (fn) {
        const url = `TeslaCam/${group}/${seqName}/${fn}`;
        if (v.src.endsWith(fn) || v.dataset.clip === url) continue;
        if (!encrypted) {
          v.src = url;
          continue;
        }
        v.dataset.clip = url;
        (async () => {
          try {
            const resp = await fetch(url);
            if (!resp.ok) throw new Error(`could not fetch ${fn} (${resp.status})`);
            const bytes = new Uint8Array(await resp.arrayBuffer());
            const key = await fetchClipKey(readClipHeader(bytes), teslaToken);
            const mp4 = await decryptClip(bytes, key);
            if (cancelled) return;
            const old = blobUrls.current[c];
            if (old) URL.revokeObjectURL(old);
            const blob = URL.createObjectURL(
              new Blob([mp4.buffer as ArrayBuffer], { type: 'video/mp4' }),
            );
            blobUrls.current[c] = blob;
            v.src = blob;
            setDecryptError(null);
          } catch (e) {
            if (cancelled) return;
            delete v.dataset.clip;
            if (e instanceof TokenError) {
              setTeslaToken('');
              setTeslaTokenState('');
              setTokenModal({ open: true, expired: true });
            } else {
              setDecryptError(e instanceof Error ? e.message : String(e));
            }
          }
        })();
      } else {
        delete v.dataset.clip;
        v.removeAttribute('src');
        v.load();
      }
    }
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [current, group, seqName, teslaToken]);

  // Decrypted video is held in memory as blob URLs; let it go when the viewer is left.
  useEffect(
    () => () => {
      for (const u of Object.values(blobUrls.current)) URL.revokeObjectURL(u);
    },
    [],
  );

  // Sentry map from event json
  useEffect(() => {
    setMapUrl('');
    const jf = jsonBySeq[`${group}/${seqName}`];
    if (!jf) return;
    api
      .readLog('TeslaCam/' + jf)
      .then((txt) => {
        try {
          const j = JSON.parse(txt);
          if (j.est_lat && j.est_lon) {
            const w = mapDivRef.current?.clientWidth || 300;
            const h = mapDivRef.current?.clientHeight || 200;
            setMapUrl(
              `https://www.bing.com/maps/embed?w=${w}&h=${h}&cp=${j.est_lat}~${j.est_lon}&lvl=17&typ=d&sty=h&src=SHELL&FORM=MBEDV8`,
            );
          }
        } catch {
          /* ignore */
        }
      })
      .catch(() => {});
  }, [group, seqName, jsonBySeq]);

  function selectSequence(g: string, name: string) {
    pauseAll();
    setGroup(g);
    setSeqName(name);
    setSegIdx(0);
    setPosMs(0);
    setPlaying(false);
  }

  function activeVideos(): HTMLVideoElement[] {
    if (!current) return [];
    return CAMS.filter((c) => current.cameras[c])
      .map((c) => videoRefs.current[c])
      .filter((v): v is HTMLVideoElement => !!v);
  }

  // Buffering = any active camera doesn't yet have enough data to play through.
  function refreshBuffering() {
    const vids = activeVideos();
    setBuffering(vids.length > 0 && vids.some((v) => v.readyState < 3 /* HAVE_FUTURE_DATA */));
  }
  const bufHandlers = {
    onWaiting: refreshBuffering,
    onStalled: refreshBuffering,
    onPlaying: refreshBuffering,
    onCanPlay: refreshBuffering,
    onLoadedData: refreshBuffering,
    onLoadStart: () => setBuffering(true),
  };

  function playAll() {
    activeVideos().forEach((v) => v.play().catch(() => {}));
    setPlaying(true);
  }
  function pauseAll() {
    activeVideos().forEach((v) => v.pause());
    setPlaying(false);
  }
  function togglePlay() {
    playing ? pauseAll() : playAll();
  }

  // YouTube-style controls: visible on activity + while paused, fade after idle when playing.
  function pokeControls() {
    setControlsVisible(true);
    window.clearTimeout(hideTimer.current);
    hideTimer.current = window.setTimeout(() => setControlsVisible(false), 2500);
  }
  useEffect(() => {
    if (!playing) {
      window.clearTimeout(hideTimer.current);
      setControlsVisible(true);
    } else {
      pokeControls();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing]);

  function seekGlobal(ms: number) {
    if (ms < 0) ms = 0;
    if (ms > durationMs - 1) ms = durationMs - 1;
    const idx = Math.floor(ms / SEG_MS);
    if (idx !== segIdx) {
      setSegIdx(idx);
      setTimeout(() => {
        activeVideos().forEach((v) => (v.currentTime = (ms % SEG_MS) / 1000));
        if (playing) playAll();
      }, 60);
    } else {
      activeVideos().forEach((v) => (v.currentTime = (ms % SEG_MS) / 1000));
    }
    setPosMs(ms);
  }

  const seekToClientX = (clientX: number) => {
    const el = seekRef.current;
    const dur = durationRef.current;
    if (!el || !dur) return;
    const rect = el.getBoundingClientRect();
    const frac = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    paintBar(frac * 100);
    seekGlobal(frac * dur);
  };

  function onMasterTimeUpdate() {
    const m = masterCam();
    if (m && !scrubbing.current) setPosMs(segIdx * SEG_MS + m.currentTime * 1000);
  }
  function onMasterEnded() {
    if (segIdx + 1 < segments.length) {
      setSegIdx(segIdx + 1);
      setTimeout(() => {
        if (playing) playAll();
      }, 80);
    } else {
      setPlaying(false);
    }
  }

  const orderedSeqs = group
    ? Object.keys(groups[group] || {})
        .sort()
        .reverse()
    : [];
  function prevNextClip(dir: 'prev' | 'next') {
    const i = orderedSeqs.indexOf(seqName);
    const ni = dir === 'prev' ? i - 1 : i + 1;
    if (ni >= 0 && ni < orderedSeqs.length) selectSequence(group, orderedSeqs[ni]);
  }

  const groupOptions: SelectProps.Option[] = Object.keys(groups)
    .sort((a, b) => GROUP_ORDER.indexOf(a) - GROUP_ORDER.indexOf(b))
    .map((g) => ({ value: g, label: groupLabel(g) }));
  const seqOptions: SelectProps.Option[] = group
    ? Object.keys(groups[group] || {})
        .sort()
        .reverse()
        .map((s) => ({
          value: s,
          label: s.replace('_', ' ').replace(/-/g, (m, i) => (i > 9 ? ':' : '-')),
        }))
    : [];

  // Live timestamp = current segment start advanced by the offset within it.
  const base = current ? segStartDate(current.ts) : null;
  const displayDate = base ? new Date(base.getTime() + (posMs - segIdx * SEG_MS)) : null;

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Synchronized multi-camera playback of TeslaCam footage">
          Camera Viewer
        </Header>
      }
    >
      <SpaceBetween size="m">
        {group && isEncryptedGroup(group) && !teslaToken && (
          // The files keep their .mp4 names but are AES-encrypted containers, so a browser
          // cannot play them as they are. With a token from Tesla's own viewer, this page can
          // fetch the per-clip keys and decrypt locally, exactly as dashcam.tesla.com does.
          <Alert
            type="info"
            header="These clips are encrypted"
            action={
              <Button onClick={() => setTokenModal({ open: true, expired: false })}>
                Play them here
              </Button>
            }
          >
            The car saved these with Encrypt Dashcam Recordings turned on. They are archived like
            any other clip. To play them in this viewer, sign in at Tesla&apos;s dashcam site and
            paste its token; the video is decrypted in your browser and never leaves it.
          </Alert>
        )}
        {group && isEncryptedGroup(group) && teslaToken && decryptError && (
          <Alert
            type="error"
            header="Could not decrypt this clip"
            dismissible
            onDismiss={() => setDecryptError(null)}
            action={
              <Button onClick={() => setTokenModal({ open: true, expired: false })}>
                Change token
              </Button>
            }
          >
            {decryptError}
          </Alert>
        )}
        <TeslaTokenModal
          visible={tokenModal.open}
          expired={tokenModal.expired}
          onDismiss={() => setTokenModal({ open: false, expired: false })}
          onSaved={(tok) => {
            setTeslaTokenState(tok);
            setDecryptError(null);
            setTokenModal({ open: false, expired: false });
          }}
        />
        <SpaceBetween direction="horizontal" size="xs">
          <Select
            selectedOption={group ? { value: group, label: groupLabel(group) } : null}
            onChange={(e) => {
              const g = e.detail.selectedOption.value!;
              const seqs = Object.keys(groups[g] || {})
                .sort()
                .reverse();
              selectSequence(g, seqs[0] || '');
            }}
            options={groupOptions}
            placeholder="Category"
          />
          <Select
            selectedOption={seqName ? { value: seqName, label: seqName } : null}
            onChange={(e) => selectSequence(group, e.detail.selectedOption.value!)}
            options={seqOptions}
            placeholder="Clip"
            filteringType="auto"
          />
          <Select
            selectedOption={LAYOUTS.find((l) => l.value === layout) || LAYOUTS[0]}
            onChange={(e) => setLayout(e.detail.selectedOption.value!)}
            options={LAYOUTS}
          />
        </SpaceBetween>

        {loading ? (
          <Box textAlign="center" padding="xxl" color="inherit">
            Loading clips…
          </Box>
        ) : segments.length === 0 ? (
          <Box textAlign="center" padding="xxl" color="inherit">
            No recordings found.
          </Box>
        ) : (
          <div
            className={`tcv-player ${!playing || controlsVisible ? 'tcv-show' : ''}`}
            onPointerMove={pokeControls}
            onPointerDown={pokeControls}
          >
            <div
              className={`tv-grid ${layout}`}
              style={{ aspectRatio: '3 / 2' }}
              onClick={togglePlay}
            >
              <video
                ref={(el) => (videoRefs.current.front = el)}
                className="frontview"
                playsInline
                muted
                {...bufHandlers}
                onTimeUpdate={onMasterTimeUpdate}
                onEnded={onMasterEnded}
              />
              <video
                ref={(el) => (videoRefs.current.left_repeater = el)}
                className="leftrepeaterview tv-flip"
                playsInline
                muted
                {...bufHandlers}
              />
              <video
                ref={(el) => (videoRefs.current.right_repeater = el)}
                className="rightrepeaterview tv-flip"
                playsInline
                muted
                {...bufHandlers}
              />
              <video
                ref={(el) => (videoRefs.current.back = el)}
                className="backview"
                playsInline
                muted
                {...bufHandlers}
              />
              <div ref={mapDivRef} className="mapview tv-cell">
                {mapUrl ? (
                  <iframe className="tv-mapframe" title="Sentry location" src={mapUrl} />
                ) : (
                  <Box textAlign="center" color="inherit" padding="m">
                    No location
                  </Box>
                )}
              </div>
              <div className="infoview tv-cell">
                <div>{seqName}</div>
                <div>
                  Segment {segIdx + 1} / {segments.length}
                </div>
              </div>
            </div>

            {buffering && (
              <div className="tcv-spinner">
                <div className="tcv-spinner-ring" />
                <span>Buffering…</span>
              </div>
            )}

            {/* Top overlay: live timestamp */}
            <div className="tcv-overlay tcv-overlay-top">
              <span className="tcv-time">
                <Ico n="camera-video" />
                {displayDate ? formatDateTime(displayDate) : seqName}
              </span>
            </div>

            {/* Bottom overlay: seek bar + transport + download */}
            <div className="tcv-overlay tcv-overlay-bottom">
              <div
                className="tcv-seek"
                ref={seekRef}
                onClick={(e) => e.stopPropagation()}
                onPointerDown={(e) => {
                  e.stopPropagation();
                  e.currentTarget.setPointerCapture(e.pointerId);
                  scrubbing.current = true;
                  seekToClientX(e.clientX);
                }}
                onPointerMove={(e) => {
                  if (scrubbing.current) seekToClientX(e.clientX);
                }}
                onPointerUp={(e) => {
                  scrubbing.current = false;
                  try {
                    e.currentTarget.releasePointerCapture(e.pointerId);
                  } catch {
                    /* ignore */
                  }
                }}
              >
                <div className="tcv-seek-fill" ref={fillRef} />
                <div className="tcv-seek-handle" ref={handleRef} />
              </div>
              <div className="tcv-controls-row" onClick={(e) => e.stopPropagation()}>
                <div className="tcv-group">
                  <button
                    className="tcv-btn"
                    onClick={() => prevNextClip('prev')}
                    aria-label="Previous clip"
                  >
                    <Ico n="chevron-left" />
                  </button>
                  <button
                    className="tcv-btn"
                    onClick={() => seekGlobal(posMs - 10000)}
                    aria-label="Rewind 10 seconds"
                  >
                    <Ico n="ccw" />
                    <span className="tcv-skip-num">10</span>
                  </button>
                  <button
                    className="tcv-btn tcv-play"
                    onClick={togglePlay}
                    aria-label={playing ? 'Pause' : 'Play'}
                  >
                    <Ico n={playing ? 'pause' : 'play'} />
                  </button>
                  <button
                    className="tcv-btn"
                    onClick={() => seekGlobal(posMs + 10000)}
                    aria-label="Skip forward 10 seconds"
                  >
                    <Ico n="cw" />
                    <span className="tcv-skip-num">10</span>
                  </button>
                  <button
                    className="tcv-btn"
                    onClick={() => prevNextClip('next')}
                    aria-label="Next clip"
                  >
                    <Ico n="chevron-right" />
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
      </SpaceBetween>
    </ContentLayout>
  );
}
