export function uptimeString(secs: number): string {
  secs = Math.round(secs);
  const days = Math.trunc(secs / 86400);
  const hours = Math.trunc((secs % 86400) / 3600);
  const minutes = Math.trunc((secs % 3600) / 60);
  const seconds = Math.trunc(secs % 60);
  let out = '';
  if (days === 1) out = '1 day, ';
  else if (days > 1) out = days + ' days, ';
  const p = (n: number) => n.toString().padStart(2, '0');
  return out + p(hours) + ':' + p(minutes) + ':' + p(seconds);
}

export function spaceString(bytes: number): string {
  if (bytes > 1024 ** 3) return (bytes / 1024 ** 3).toFixed(bytes > 100 * 1024 ** 2 ? 1 : 0) + ' G';
  return (bytes / 1024 ** 2).toFixed(0) + ' M';
}

export function dateFromSeconds(seconds: number): string {
  const d = new Date(0);
  d.setUTCSeconds(seconds);
  return new Intl.DateTimeFormat(navigator.language, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  }).format(d);
}

export function byteRate(bitsPerSec: number): string {
  const bps = bitsPerSec / 8;
  if (bps > 500000) return (bps / 1024 ** 2).toFixed(1) + ' MB/s';
  return (bps / 1024).toFixed(1) + ' KB/s';
}

export function bitRate(bitsPerSec: number): string {
  return (bitsPerSec / 1e6).toFixed(bitsPerSec < 2.5e6 ? 1 : 0) + ' Mbit/s';
}

// wifi_strength like "57/70" -> percent
export function wifiPercent(s: string): number | null {
  const m = s.match(/(\d+)\s*\/\s*(\d+)/);
  if (!m) return null;
  const a = parseInt(m[1], 10);
  const b = parseInt(m[2], 10);
  if (!b) return null;
  return Math.round((a / b) * 100);
}

const THROTTLE_FLAGS: [number, string][] = [
  [0, 'Undervoltage detected'],
  [1, 'Arm frequency capped'],
  [2, 'Currently throttled'],
  [3, 'Soft temperature limit active'],
  [16, 'Undervoltage has occurred since last reboot'],
  [17, 'Arm frequency capping has occurred since last reboot'],
  [18, 'Throttling has occurred since last reboot'],
  [19, 'Soft temperature limit has occurred since last reboot'],
];

export function throttleFlags(hex: string): string[] {
  const bits = parseInt(hex, 16);
  if (Number.isNaN(bits)) return [];
  return THROTTLE_FLAGS.filter(([bit]) => (bits & (1 << bit)) !== 0).map(([, label]) => label);
}

// Convert log line timestamps like "Tue 19 May 17:04:37 BST 2026 : msg" to UTC.
// GMT/UTC pass through unchanged (reformatted as UTC); BST is shifted back 1h.
// Lines without a recognized leading timestamp are returned untouched.
const _LOG_MON: Record<string, number> = {
  Jan: 0,
  Feb: 1,
  Mar: 2,
  Apr: 3,
  May: 4,
  Jun: 5,
  Jul: 6,
  Aug: 7,
  Sep: 8,
  Oct: 9,
  Nov: 10,
  Dec: 11,
};
const _LOG_TZ_OFFSET_MIN: Record<string, number> = { UTC: 0, GMT: 0, BST: 60 };
const _LOG_WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const _LOG_MN = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

export function logToUtc(text: string): string {
  return text
    .split('\n')
    .map((line) => {
      const m = line.match(
        /^[A-Z][a-z]{2}\s+(\d{1,2})\s+([A-Z][a-z]{2})\s+(\d{2}):(\d{2}):(\d{2})\s+([A-Z]{2,4})\s+(\d{4})/,
      );
      if (!m) return line;
      const off = _LOG_TZ_OFFSET_MIN[m[6]];
      const mon = _LOG_MON[m[2]];
      if (off === undefined || mon === undefined) return line;
      const d = new Date(Date.UTC(+m[7], mon, +m[1], +m[3], +m[4], +m[5]) - off * 60000);
      const p = (n: number) => String(n).padStart(2, '0');
      const stamp = `${_LOG_WD[d.getUTCDay()]} ${p(d.getUTCDate())} ${_LOG_MN[d.getUTCMonth()]} ${p(
        d.getUTCHours(),
      )}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())} UTC ${d.getUTCFullYear()}`;
      return stamp + line.slice(m[0].length);
    })
    .join('\n');
}
