import { useContext, useEffect, useRef, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import ColumnLayout from '@cloudscape-design/components/column-layout';
import Box from '@cloudscape-design/components/box';
import SpaceBetween from '@cloudscape-design/components/space-between';
import StatusIndicator from '@cloudscape-design/components/status-indicator';
import Icon from '@cloudscape-design/components/icon';
import Popover from '@cloudscape-design/components/popover';
import Button from '@cloudscape-design/components/button';
import Alert from '@cloudscape-design/components/alert';
import Container from '@cloudscape-design/components/container';
import Grid from '@cloudscape-design/components/grid';
import PieChart from '@cloudscape-design/components/pie-chart';
import * as api from '../api';
import { Config, Status, CamUsage } from '../api';
import { uptimeString, spaceString, dateFromSeconds, wifiPercent, throttleFlags } from '../format';
import { ThemeContext } from '../theme';

const POLL_MS = 1000;

function Value({
  label,
  info,
  children,
}: {
  label: string;
  info?: string;
  children: React.ReactNode;
}) {
  return (
    <div>
      <Box variant="awsui-key-label">
        {label}
        {info && (
          <Popover
            dismissButton={false}
            position="top"
            size="small"
            triggerType="custom"
            content={info}
          >
            <span style={{ marginLeft: 4, cursor: 'help', verticalAlign: 'middle' }}>
              <Icon name="status-info" size="small" variant="subtle" />
            </span>
          </Popover>
        )}
      </Box>
      <div className="tu-val">{children}</div>
    </div>
  );
}

function Skel({ w = 130 }: { w?: number }) {
  return (
    <span className="tu-skel" style={{ width: w }}>
      &nbsp;
    </span>
  );
}

// Raspberry Pi temp ranges: <60 ideal, 60-80 caution, >=80 critical/throttle.
function tempEmoji(celsius: number): string {
  if (celsius < 60) return '😊';
  if (celsius < 80) return '🥵';
  return '💀';
}

// Boot time in UTC, derived from uptime.
function bootTimeUTC(uptimeSecs: number): string {
  const d = new Date(Date.now() - uptimeSecs * 1000);
  return d.toISOString().slice(0, 19).replace('T', ' ') + ' UTC';
}

function wifiBand(freqHz: number): string {
  const ghz = freqHz / 1e9;
  if (ghz >= 4.9 && ghz <= 5.9) return '5 GHz';
  if (ghz >= 2.3 && ghz <= 2.5) return '2.4 GHz';
  return ghz.toFixed(2) + ' GHz';
}

function SignalBar({ pct, dark }: { pct: number; dark: boolean }) {
  // good >=70% (~ -60 dBm), fair 40-70% (~ -60 to -75 dBm), poor <40% (~ < -75 dBm)
  const color = pct >= 70 ? '#037f0c' : pct >= 40 ? '#f0b429' : '#d91515';
  return (
    <div
      style={{
        background: dark ? '#2a313a' : '#e9ebed',
        borderRadius: 6,
        height: 10,
        overflow: 'hidden',
        marginTop: 4,
      }}
    >
      <div
        style={{
          width: `${Math.min(100, pct)}%`,
          height: '100%',
          background: color,
          transition: 'width .3s ease',
        }}
      />
    </div>
  );
}

function DiskBar({ pct, info, dark }: { pct: number; info: string; dark: boolean }) {
  const color = pct >= 90 ? '#d91515' : pct >= 75 ? '#f0b429' : '#037f0c';
  return (
    <div>
      <Box variant="awsui-key-label">Disk usage</Box>
      <div
        style={{
          background: dark ? '#2a313a' : '#e9ebed',
          borderRadius: 6,
          height: 10,
          overflow: 'hidden',
          marginTop: 4,
        }}
      >
        <div
          style={{
            width: `${Math.min(100, pct)}%`,
            height: '100%',
            background: color,
            transition: 'width .3s ease',
          }}
        />
      </div>
      <Box variant="small" padding={{ top: 'xxs' }}>
        <span className="tu-val">
          {info} — {pct.toFixed(0)}%
        </span>
      </Box>
    </div>
  );
}

function TempBar({ celsius, dark }: { celsius: number; dark: boolean }) {
  const MAX = 85; // Pi max before shutdown; throttles at 80
  const pct = Math.min(100, (celsius / MAX) * 100);
  const color = celsius >= 80 ? '#d91515' : celsius >= 60 ? '#f0b429' : '#037f0c';
  return (
    <div>
      <Box variant="awsui-key-label">Core temperature</Box>
      <div
        style={{
          background: dark ? '#2a313a' : '#e9ebed',
          borderRadius: 6,
          height: 10,
          overflow: 'hidden',
          marginTop: 4,
        }}
      >
        <div
          style={{
            width: `${pct}%`,
            height: '100%',
            background: color,
            transition: 'width .3s ease',
          }}
        />
      </div>
      <Box variant="small" padding={{ top: 'xxs' }}>
        <span className="tu-val">
          {celsius.toFixed(1)} °C {tempEmoji(celsius)}
        </span>
      </Box>
    </div>
  );
}

export default function Dashboard({ config }: { config: Config | null }) {
  const dark = useContext(ThemeContext);
  const [status, setStatus] = useState<Status | null>(null);
  const [archiveActive, setArchiveActive] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const [toggling, setToggling] = useState(false);
  const timer = useRef<number>();
  const [camUsage, setCamUsage] = useState<CamUsage | null>(null);
  // Distinct from camUsage staying null: null means "still loading", this means
  // the request finished and failed. Without it a failed fetch left the panel
  // shimmering forever, which is what a non-executable camusage.sh looked like.
  const [camUsageError, setCamUsageError] = useState<string | null>(null);
  const hasCam = config?.has_cam === 'yes';

  useEffect(() => {
    if (!hasCam) return;
    api
      .getCamUsage()
      .then((u) => {
        setCamUsage(u);
        setCamUsageError(null);
      })
      .catch((e: unknown) => setCamUsageError(e instanceof Error ? e.message : String(e)));
  }, [hasCam]);

  async function load() {
    try {
      const [st, arch] = await Promise.all([api.getStatus(), api.getArchiveStatus()]);
      setStatus(st);
      setArchiveActive(arch);
      setError(null);
    } catch (e: any) {
      setError(String(e?.message || e));
    }
  }

  useEffect(() => {
    load();
    timer.current = window.setInterval(load, POLL_MS);
    return () => window.clearInterval(timer.current);
  }, []);

  async function onToggleDrives() {
    setToggling(true);
    try {
      await api.toggleDrives();
      setTimeout(load, 1500);
    } finally {
      setToggling(false);
    }
  }

  const loading = status === null;
  const throttle = status ? throttleFlags(status.throttled) : [];
  const usedPct =
    status && status.total_space
      ? ((status.total_space - status.free_space) / status.total_space) * 100
      : 0;
  const wifi = status ? wifiPercent(status.wifi_strength) : null;
  const tempC = status && status.cpu_temp ? Number(status.cpu_temp) / 1000 : null;
  const usageData = camUsage
    ? [
        { title: 'RecentClips', value: camUsage.RecentClips, color: '#0972d3' },
        { title: 'SentryClips', value: camUsage.SentryClips, color: '#e07941' },
        { title: 'SavedClips', value: camUsage.SavedClips, color: '#037f0c' },
      ].filter((d) => d.value > 0)
    : [];
  const usageTotal = camUsage
    ? camUsage.RecentClips + camUsage.SentryClips + camUsage.SavedClips
    : 0;

  const systemContent = (
    <SpaceBetween size="m">
      <ColumnLayout columns={2} variant="text-grid">
        <Value label="Uptime">
          {loading ? (
            <Skel />
          ) : (
            `${uptimeString(status!.uptime)} (since ${bootTimeUTC(status!.uptime)})`
          )}
        </Value>
        <Value label="Drives">
          {loading ? (
            <Skel w={150} />
          ) : (
            <StatusIndicator type={status!.drives_active === 'yes' ? 'success' : 'stopped'}>
              {status!.drives_active === 'yes' ? 'Visible to Tesla' : 'Not visible to Tesla'}
            </StatusIndicator>
          )}
        </Value>
        <Value label="Archive run">
          {loading ? (
            <Skel w={120} />
          ) : archiveActive ? (
            <StatusIndicator type="in-progress">Archiving…</StatusIndicator>
          ) : (
            <StatusIndicator type="stopped">Idle</StatusIndicator>
          )}
        </Value>
        {!loading && status!.fan_speed && status!.fan_speed !== 'N/A' && (
          <Value label="Fan speed">{status!.fan_speed} RPM</Value>
        )}
        {!loading && status!.external_5v && status!.external_5v !== 'N/A' && (
          <Value label="External 5V">{parseFloat(status!.external_5v).toFixed(3)} V</Value>
        )}
        {!loading &&
          status!.rtc_batt_v &&
          status!.rtc_batt_v !== 'N/A' &&
          parseFloat(status!.rtc_batt_v) >= 2.5 && (
            <Value label="RTC battery">{parseFloat(status!.rtc_batt_v).toFixed(3)} V</Value>
          )}
      </ColumnLayout>
      {loading ? (
        <div>
          <Box variant="awsui-key-label">Core temperature</Box>
          <span className="tu-skel tu-skel-bar" />
        </div>
      ) : tempC != null ? (
        <TempBar celsius={tempC} dark={dark} />
      ) : null}
      <Button loading={toggling} disabled={loading} onClick={onToggleDrives}>
        {status?.drives_active === 'yes'
          ? 'Disconnect drives from Tesla'
          : 'Connect drives to Tesla'}
      </Button>
    </SpaceBetween>
  );

  const storageContent = (
    <SpaceBetween size="m">
      {loading ? (
        <div>
          <Box variant="awsui-key-label">Disk usage</Box>
          <span className="tu-skel tu-skel-bar" />
        </div>
      ) : (
        <DiskBar
          pct={usedPct}
          dark={dark}
          info={`${spaceString(status!.total_space - status!.free_space)} used of ${spaceString(status!.total_space)} (${spaceString(status!.free_space)} free)`}
        />
      )}
      <Value
        label="Disk snapshots"
        info="Block-level snapshots of the dashcam disk that teslausb takes so it can archive footage consistently while the car keeps recording. This is an internal backup mechanism, not a count of video clips (Recent/Sentry/Saved)."
      >
        {loading ? (
          <Skel w={220} />
        ) : (
          status!.num_snapshots +
          (status!.num_snapshots > 0
            ? ' (' +
              dateFromSeconds(status!.snapshot_oldest) +
              (status!.num_snapshots > 1 ? ' – ' + dateFromSeconds(status!.snapshot_newest) : '') +
              ')'
            : '')
        )}
      </Value>
    </SpaceBetween>
  );

  const networkContent = loading ? (
    <SpaceBetween size="m">
      <Skel w={220} />
      <span className="tu-skel tu-skel-bar" />
    </SpaceBetween>
  ) : status!.wifi_ssid ? (
    <SpaceBetween size="m">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Icon name="status-positive" variant="success" />
        <Box fontSize="heading-xl" fontWeight="bold">
          {status!.wifi_ssid}
        </Box>
      </div>
      {wifi != null && (
        <div>
          <Box variant="awsui-key-label">Signal quality</Box>
          <SignalBar pct={wifi} dark={dark} />
          <Box variant="small" padding={{ top: 'xxs' }}>
            <span className="tu-val">
              {wifi}% link quality{status!.wifi_strength ? ` (${status!.wifi_strength})` : ''}
            </span>
          </Box>
        </div>
      )}
      <ColumnLayout columns={3} variant="text-grid">
        <Value label="Connection">Wi-Fi</Value>
        <Value label="Band">{status!.wifi_freq ? wifiBand(Number(status!.wifi_freq)) : '—'}</Value>
        <Value label="IP address">{status!.wifi_ip || 'no IP assigned'}</Value>
      </ColumnLayout>
      {status!.ether_speed && status!.ether_speed !== 'Unknown!' && (
        <Value label="Ethernet">
          {status!.ether_speed}, {status!.ether_ip}
        </Value>
      )}
    </SpaceBetween>
  ) : (
    <SpaceBetween size="m">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <Icon name="status-negative" variant="error" />
        <Box fontSize="heading-l">Wi-Fi not connected</Box>
      </div>
      {status!.ether_speed && status!.ether_speed !== 'Unknown!' && (
        <Value label="Ethernet">
          {status!.ether_speed}, {status!.ether_ip}
        </Value>
      )}
    </SpaceBetween>
  );

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Live status of your teslausb device">
          Dashboard
        </Header>
      }
    >
      <SpaceBetween size="l">
        {error && (
          <Alert type="error" header="Could not reach the device">
            {error}
          </Alert>
        )}
        {throttle.length > 0 && (
          <Alert type="warning" header="Power / thermal warnings">
            <ul style={{ margin: 0, paddingLeft: 18 }}>
              {throttle.map((t) => (
                <li key={t}>{t}</li>
              ))}
            </ul>
          </Alert>
        )}
        <Grid
          gridDefinition={[{ colspan: { default: 12, s: 6 } }, { colspan: { default: 12, s: 6 } }]}
        >
          <Container header={<Header variant="h2">System</Header>} fitHeight>
            {systemContent}
          </Container>
          <Container header={<Header variant="h2">Storage</Header>} fitHeight>
            {storageContent}
          </Container>
        </Grid>
        {hasCam && (
          <Container
            header={
              <Header variant="h2" description="Space used by each recording category">
                Recordings storage
              </Header>
            }
          >
            {camUsageError !== null ? (
              <Alert type="error" header="Could not read recording sizes">
                {camUsageError}
              </Alert>
            ) : camUsage === null ? (
              <Box textAlign="center" padding={{ vertical: 'l' }}>
                <div
                  className="tu-skel"
                  style={{ width: 160, height: 160, borderRadius: '50%', margin: '0 auto' }}
                />
                <Box padding={{ top: 'm' }}>
                  <div
                    className="tu-skel"
                    style={{ width: 220, height: 14, borderRadius: 6, margin: '6px auto' }}
                  />
                  <div
                    className="tu-skel"
                    style={{ width: 160, height: 14, borderRadius: 6, margin: '6px auto' }}
                  />
                </Box>
              </Box>
            ) : (
              <PieChart
                data={usageData}
                variant="donut"
                size="medium"
                statusType="finished"
                hideFilter
                innerMetricValue={spaceString(usageTotal)}
                innerMetricDescription="total"
                detailPopoverContent={(d, sum) => [
                  { key: 'Size', value: spaceString(d.value) },
                  { key: 'Share', value: ((d.value / sum) * 100).toFixed(1) + '%' },
                ]}
                segmentDescription={(d, sum) =>
                  `${spaceString(d.value)} (${((d.value / sum) * 100).toFixed(0)}%)`
                }
                ariaLabel="Recordings space breakdown"
                empty={
                  <Box textAlign="center" color="inherit">
                    No recordings.
                  </Box>
                }
              />
            )}
          </Container>
        )}
        <Container header={<Header variant="h2">Network</Header>}>{networkContent}</Container>
      </SpaceBetween>
    </ContentLayout>
  );
}
