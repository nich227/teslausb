// API client for the teslausb cgi-bin backend (nginx + fcgiwrap shell scripts).
// All endpoints are served from the same origin; cgi scripts live under /cgi-bin/.

const CGI = 'cgi-bin/';

function bust(url: string): string {
  return url + (url.includes('?') ? '&' : '?') + '_=' + Date.now();
}

export interface Status {
  uptime: number;
  cpu_temp: string;
  fan_speed: string;
  external_5v: string;
  rtc_batt_v: string;
  throttled: string;
  drives_active: string; // "yes" | "no"
  total_space: number;
  free_space: number;
  num_snapshots: number;
  snapshot_oldest: number;
  snapshot_newest: number;
  ether_speed: string;
  ether_ip: string;
  wifi_ssid: string;
  wifi_freq: string;
  wifi_strength: string; // e.g. "57/70"
  wifi_ip: string;
}

export interface Config {
  has_cam: string;
  has_music: string;
  has_lightshow: string;
  has_boombox: string;
  uses_ble: string;
}

export async function getStatus(): Promise<Status> {
  const r = await fetch(bust(CGI + 'status.sh'), { cache: 'no-store' });
  if (!r.ok) throw new Error('status ' + r.status);
  return r.json();
}

export async function getConfig(): Promise<Config> {
  const r = await fetch(bust(CGI + 'config.sh'), { cache: 'no-store' });
  if (!r.ok) throw new Error('config ' + r.status);
  return r.json();
}

// Whether an archive/sync run is currently active (archivestatus.sh).
export async function getArchiveStatus(): Promise<boolean> {
  try {
    const r = await fetch(bust(CGI + 'archivestatus.sh'), { cache: 'no-store' });
    if (!r.ok) return false;
    const ct = r.headers.get('content-type') || '';
    if (ct.includes('text/html')) return false;
    const j = await r.json();
    return j.archiving === 'yes';
  } catch {
    return false;
  }
}

// Whether the root filesystem is currently read-write.
export async function getRwStatus(): Promise<boolean> {
  try {
    const r = await fetch(bust(CGI + 'rwstatus.sh'), { cache: 'no-store' });
    if (!r.ok) return false;
    const ct = r.headers.get('content-type') || '';
    if (ct.includes('text/html')) return false;
    const j = await r.json();
    return j.rw === 'yes';
  } catch {
    return false;
  }
}

// Enable read-write mode; returns the resulting rw state.
export async function enableRw(): Promise<boolean> {
  const r = await fetch(bust(CGI + 'remountrw.sh'), { cache: 'no-store' });
  if (!r.ok) throw new Error('remountrw ' + r.status);
  const j = await r.json();
  return j.rw === 'yes';
}

export interface CamUsage {
  RecentClips: number;
  SentryClips: number;
  SavedClips: number;
}

// Bytes used per TeslaCam category (camusage.sh). May take a few seconds (du).
export async function getCamUsage(): Promise<CamUsage> {
  const r = await fetch(bust(CGI + 'camusage.sh'), { cache: 'no-store' });
  if (!r.ok) throw new Error('camusage ' + r.status);
  return r.json();
}

export async function getVideoList(): Promise<string[]> {
  const r = await fetch(bust(CGI + 'videolist.sh'), { cache: 'no-store' });
  const text = await r.text();
  return text.split('\n').filter((l) => l.trim() !== '');
}

// Directory listing via ls.sh. Returns parsed entries.
export interface LsEntry {
  type: 'dir' | 'file';
  name: string;
  path: string;
  size?: number;
  hasChildren?: boolean;
}
export interface LsResult {
  entries: LsEntry[];
  fsTotal?: number;
  fsFree?: number;
}

export async function ls(root: string, path = ''): Promise<LsResult> {
  // NOTE: ls.sh parses '&'-separated query args positionally (arg0=root,
  // arg1=path), so we must NOT append a cache-buster here. Use no-store instead.
  const qs = encodeURIComponent(root) + (path ? '&' + encodeURIComponent(path) : '');
  const r = await fetch(CGI + 'ls.sh?' + qs, { cache: 'no-store' });
  const text = await r.text();
  const entries: LsEntry[] = [];
  let fsTotal: number | undefined;
  let fsFree: number | undefined;
  const childDirs = new Set<string>();
  for (const line of text.split('\n')) {
    if (!line) continue;
    const kind = line[0];
    const rest = line.slice(2);
    if (kind === 'd') {
      entries.push({ type: 'dir', name: baseName(rest), path: rest });
    } else if (kind === 'f') {
      const idx = rest.lastIndexOf(':');
      const p = rest.slice(0, idx);
      const sz = parseInt(rest.slice(idx + 1), 10);
      entries.push({ type: 'file', name: baseName(p), path: p, size: isNaN(sz) ? undefined : sz });
    } else if (kind === 'D') {
      // marks a directory (depth 2) that itself contains entries
      childDirs.add(parentDir(rest));
    } else if (kind === 's') {
      const parts = rest.split(':');
      fsTotal = parseInt(parts[0], 10);
      fsFree = parseInt(parts[1], 10);
    }
  }
  for (const e of entries) {
    if (e.type === 'dir' && childDirs.has(e.path)) e.hasChildren = true;
  }
  return { entries, fsTotal, fsFree };
}

function baseName(p: string): string {
  const i = p.replace(/\/+$/, '').lastIndexOf('/');
  return i >= 0 ? p.slice(i + 1) : p;
}
function parentDir(p: string): string {
  const i = p.replace(/\/+$/, '').lastIndexOf('/');
  return i >= 0 ? p.slice(0, i) : '.';
}

// Plain control endpoints
export async function triggerSync(): Promise<void> {
  await fetch(bust(CGI + 'trigger_sync.sh'), { cache: 'no-store' });
}
export async function toggleDrives(): Promise<void> {
  await fetch(bust(CGI + 'toggledrives.sh'), { cache: 'no-store' });
}
export async function reboot(): Promise<void> {
  await fetch(bust(CGI + 'reboot.sh'), { cache: 'no-store' });
}

// BLE pairing
export async function pairBLE(): Promise<{ ok: boolean; message: string }> {
  const r = await fetch(bust(CGI + 'pairBLEkey.sh'), { cache: 'no-store' });
  const text = await r.text();
  if (r.status >= 200 && r.status < 300) {
    return { ok: true, message: 'Pairing started. Tap keycard on center console to confirm.' };
  }
  const m = text.match(/<p>(.*?)<\/p>/s);
  let msg = m ? m[1] : 'Pairing failed. Please try again.';
  if (msg.includes('maximum number of BLE devices')) {
    msg = 'Too many BLE devices active; turn off Bluetooth on nearby phone keys and try again.';
  }
  return { ok: false, message: msg };
}
export async function checkBLEStatus(): Promise<'paired' | 'pending'> {
  const r = await fetch(bust(CGI + 'checkBLEstatus.sh'), { cache: 'no-store' });
  const text = await r.text();
  return text.includes('<p>paired</p>') ? 'paired' : 'pending';
}

// Read a plain-text file. Returns '' if missing OR if the server returned HTML
// (e.g. an SPA fallback page), so we never render the app's own HTML as a log.
async function fetchText(url: string): Promise<string> {
  const r = await fetch(bust(url), { cache: 'no-store' });
  if (!r.ok) return '';
  const ct = r.headers.get('content-type') || '';
  if (ct.includes('text/html')) return '';
  return r.text();
}

// Diagnostics: trigger generation then read the result file.
// setup-teslausb's diagnose output ends with this line; we poll for it so the
// backend's "already running" lock message is never surfaced (no sentinel is
// written into the file itself).
const DIAG_DONE = '====== end of diagnostics ======';
export async function runDiagnostics(): Promise<string> {
  // Trigger generation. diagnose.sh is synchronous (returns once the run finishes)
  // and flock-guarded, so this no-ops if a run is already in progress.
  await fetch(bust(CGI + 'diagnose.sh'), { cache: 'no-store' });
  // Normally the file is already complete here. Poll briefly for the end marker in
  // case another run was in progress; fall back to returning stable (unchanging)
  // content so we never hang waiting for a marker that isn't coming.
  let prev = '';
  for (let i = 0; i < 20; i++) {
    const txt = await fetchText('diagnostics.txt');
    if (txt.includes(DIAG_DONE)) return txt;
    if (txt && txt === prev) return txt; // output stabilized
    prev = txt;
    await new Promise((r) => setTimeout(r, 1500));
  }
  return prev;
}
export async function readDiagnostics(): Promise<string> {
  return fetchText('diagnostics.txt');
}

// Logs (full read; small enough on these devices, and simple/robust)
export async function readLog(file: string): Promise<string> {
  return fetchText(file);
}

// File operations.
//
// The cgi scripts take their query arguments positionally: '&'-separated,
// where the FIRST argument is a directory to work in (relative to
// DOCUMENT_ROOT, empty meaning the document root itself) and the remaining
// ones are the underlying command's arguments. Sending a bare path as the only
// argument makes the script chdir into it and then run e.g. 'mkdir' with no
// operands at all, which always fails.
//
// For the same reason none of these may go through bust(): the '_=<timestamp>'
// it appends would arrive as an extra operand for mkdir/rm/mv/cp. Cache
// busting is unnecessary here anyway, as cache: 'no-store' already applies.
function cgiQuery(...args: string[]): string {
  return args.map(encodeURIComponent).join('&');
}

export function downloadUrl(path: string): string {
  return CGI + 'download.sh?' + cgiQuery('', path);
}
export function downloadZipUrl(paths: string[]): string {
  return CGI + 'downloadzip.sh?' + cgiQuery('', ...paths);
}
export async function mkdir(path: string): Promise<void> {
  await fetch(CGI + 'mkdir.sh?' + cgiQuery('', path), { cache: 'no-store' });
}
export async function rm(path: string): Promise<void> {
  await fetch(CGI + 'rm.sh?' + cgiQuery('', path), { cache: 'no-store' });
}
export async function mv(from: string, to: string): Promise<void> {
  await fetch(CGI + 'mv.sh?' + cgiQuery('', from, to), { cache: 'no-store' });
}
export async function cp(from: string, to: string): Promise<void> {
  await fetch(CGI + 'cp.sh?' + cgiQuery('', from, to), { cache: 'no-store' });
}
export async function uploadFile(destDir: string, file: File): Promise<void> {
  await fetch(CGI + 'upload.sh?' + cgiQuery(destDir, file.name), {
    method: 'POST',
    body: file,
    cache: 'no-store',
  });
}

// Network speed test: stream randomdata.sh and measure throughput.
export async function* speedTest(signal: AbortSignal): AsyncGenerator<number> {
  const resp = await fetch(CGI + 'randomdata.sh', { signal, cache: 'no-store' });
  const reader = resp.body!.getReader();
  let total = 0;
  const start = Date.now();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value!.length;
    const secs = (Date.now() - start) / 1000;
    yield secs > 0 ? (total * 8) / secs : 0; // bits per second
  }
}
