import { useEffect, useRef, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import Container from '@cloudscape-design/components/container';
import Button from '@cloudscape-design/components/button';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Box from '@cloudscape-design/components/box';
import Modal from '@cloudscape-design/components/modal';
import StatusIndicator from '@cloudscape-design/components/status-indicator';
import Spinner from '@cloudscape-design/components/spinner';
import * as api from '../api';
import { Config } from '../api';
import { byteRate, bitRate } from '../format';

// Lightweight live line graph (SVG) for the speed test, autoscaled to the max sample.
function LiveGraph({ values }: { values: number[] }) {
  const w = 340;
  const h = 100;
  const max = Math.max(1, ...values);
  let line = '';
  let area = '';
  if (values.length >= 2) {
    const pts = values.map((v, i) => {
      const x = (i / (values.length - 1)) * w;
      const y = h - (v / max) * (h - 6) - 3;
      return [x, y] as [number, number];
    });
    line = pts.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');
    area = `0,${h} ${line} ${w},${h}`;
  }
  return (
    <svg
      viewBox={`0 0 ${w} ${h}`}
      width="100%"
      height={h}
      preserveAspectRatio="none"
      style={{ display: 'block', border: '1px solid rgba(128,128,128,0.25)', borderRadius: 8 }}
    >
      {values.length >= 2 && (
        <>
          <polygon points={area} fill="rgba(9,114,211,0.15)" />
          <polyline
            points={line}
            fill="none"
            stroke="#0972d3"
            strokeWidth="2"
            strokeLinejoin="round"
          />
        </>
      )}
      <text x="6" y="14" fontSize="11" fill="currentColor" fontFamily="monospace" opacity="0.6">
        peak {max.toFixed(max < 10 ? 1 : 0)} Mbit/s
      </text>
    </svg>
  );
}

export default function Tools({ config }: { config: Config | null }) {
  const [syncMsg, setSyncMsg] = useState('');

  // Speed test (modal)
  const [speedModal, setSpeedModal] = useState(false);
  const [bps, setBps] = useState(0);
  const [samples, setSamples] = useState<number[]>([]);
  const [running, setRunning] = useState(false);
  const abort = useRef<AbortController | null>(null);

  // BLE
  const [bleMsg, setBleMsg] = useState('');
  const [bleBusy, setBleBusy] = useState(false);

  // Reboot
  const [rebootModal, setRebootModal] = useState(false);
  const [rebooting, setRebooting] = useState(false);
  const [rebootMsg, setRebootMsg] = useState('');
  const [refreshIn, setRefreshIn] = useState<number | null>(null);

  // Read-write mode
  const [rw, setRw] = useState<boolean | null>(null);
  const [rwBusy, setRwBusy] = useState(false);

  useEffect(() => {
    api
      .getRwStatus()
      .then(setRw)
      .catch(() => setRw(null));
  }, []);

  useEffect(() => {
    if (!speedModal) return;
    const ac = new AbortController();
    abort.current = ac;
    setRunning(true);
    setBps(0);
    setSamples([]);
    (async () => {
      let lastT = 0;
      try {
        for await (const v of api.speedTest(ac.signal)) {
          const now = Date.now();
          if (now - lastT > 300) {
            lastT = now;
            setBps(v);
            setSamples((s) => [...s, v / 1e6].slice(-80));
          }
        }
      } catch {
        /* aborted */
      } finally {
        setRunning(false);
      }
    })();
    return () => ac.abort();
  }, [speedModal]);

  function closeSpeed() {
    abort.current?.abort();
    setSpeedModal(false);
  }

  async function doSync() {
    await api.triggerSync();
    setSyncMsg('Sync triggered');
    setTimeout(() => setSyncMsg(''), 5000);
  }

  async function pairBle() {
    setBleBusy(true);
    setBleMsg('Initiating pairing request…');
    const res = await api.pairBLE();
    setBleMsg(res.message);
    if (!res.ok) {
      setBleBusy(false);
      return;
    }
    for (let i = 0; i < 13; i++) {
      await new Promise((r) => setTimeout(r, 5000));
      if ((await api.checkBLEStatus()) === 'paired') {
        setBleMsg('Successfully paired with car.');
        setBleBusy(false);
        return;
      }
    }
    setBleMsg('Pairing failed. Please try again.');
    setBleBusy(false);
  }

  async function enableRwMode() {
    setRwBusy(true);
    try {
      setRw(await api.enableRw());
    } finally {
      setRwBusy(false);
    }
  }

  async function doReboot() {
    setRebootModal(false);
    setRebooting(true);
    setRebootMsg('Reboot in progress…');
    await api.reboot();
    const poll = async () => {
      try {
        const r = await fetch('index.html?_=' + Date.now(), { cache: 'no-store' });
        if (r.ok) {
          setRebooting(false);
          setRebootMsg('Reboot complete.');
          let n = 10;
          setRefreshIn(n);
          const iv = setInterval(() => {
            n -= 1;
            setRefreshIn(n);
            if (n <= 0) {
              clearInterval(iv);
              window.location.reload();
            }
          }, 1000);
          return;
        }
      } catch {
        /* still down */
      }
      setTimeout(poll, 2000);
    };
    setTimeout(poll, 5000);
  }

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Device controls and tests">
          Tools
        </Header>
      }
    >
      <SpaceBetween size="l">
        <Container header={<Header variant="h2">Archive / Sync</Header>}>
          <SpaceBetween direction="horizontal" size="s">
            <Button iconName="slash" onClick={doSync}>
              Trigger archive/sync
            </Button>
            {syncMsg && (
              <Box variant="p" padding={{ top: 'xxs' }}>
                {syncMsg}
              </Box>
            )}
          </SpaceBetween>
        </Container>

        <Container header={<Header variant="h2">Network speed test</Header>}>
          <Button iconName="upload-download" onClick={() => setSpeedModal(true)}>
            Run network speed test
          </Button>
        </Container>

        {config?.uses_ble === 'yes' && (
          <Container header={<Header variant="h2">Bluetooth (BLE) pairing</Header>}>
            <SpaceBetween size="s">
              <Button loading={bleBusy} onClick={pairBle}>
                Pair BLE with car
              </Button>
              {bleMsg && <Box variant="p">{bleMsg}</Box>}
            </SpaceBetween>
          </Container>
        )}

        <Container header={<Header variant="h2">Filesystem mode</Header>}>
          {rw === null ? (
            <Spinner />
          ) : rw ? (
            <SpaceBetween size="s">
              <StatusIndicator type="warning">Read-write mode is enabled</StatusIndicator>
              <Box variant="p">
                The root filesystem is writable. Read-write can't be turned off while running,
                restart the Raspberry Pi to return to read-only (protects the SD card).
              </Box>
            </SpaceBetween>
          ) : (
            <SpaceBetween size="s">
              <StatusIndicator type="success">Read-only (normal)</StatusIndicator>
              <Button loading={rwBusy} onClick={enableRwMode}>
                Enable read-write mode
              </Button>
              <Box variant="small">
                Read-write can't be disabled while running; restart the Pi to return to read-only.
              </Box>
            </SpaceBetween>
          )}
        </Container>

        <Container header={<Header variant="h2">Power</Header>}>
          <SpaceBetween size="s">
            <Button iconName="refresh" loading={rebooting} onClick={() => setRebootModal(true)}>
              Restart Raspberry Pi
            </Button>
            {rebootMsg && (
              <StatusIndicator type={rebooting ? 'in-progress' : 'success'}>
                {rebootMsg}
              </StatusIndicator>
            )}
            {refreshIn !== null && (
              <Box variant="p">
                This page will refresh automatically in {refreshIn} second
                {refreshIn === 1 ? '' : 's'}…
              </Box>
            )}
          </SpaceBetween>
        </Container>
      </SpaceBetween>

      <Modal
        visible={speedModal}
        onDismiss={closeSpeed}
        header="Network speed test"
        footer={
          <Box float="right">
            <Button variant="primary" onClick={closeSpeed}>
              {running ? 'Stop' : 'Close'}
            </Button>
          </Box>
        }
      >
        <Box textAlign="center">
          <div className={`tu-radar${bps === 0 ? ' tu-radar-idle' : ''}`}>
            <div className="tu-radar-center">
              <div className="tu-radar-big">{(bps / 1e6).toFixed(bps < 2.5e6 ? 1 : 0)}</div>
              <div className="tu-radar-sub">Mbit/s</div>
            </div>
          </div>
          <Box padding={{ top: 's' }}>
            <span className="tu-val" style={{ fontSize: 18 }}>
              {byteRate(bps)} · {bitRate(bps)}
            </span>
          </Box>
          <Box padding={{ top: 's' }}>
            <LiveGraph values={samples} />
          </Box>
        </Box>
      </Modal>

      <Modal
        visible={rebootModal}
        onDismiss={() => setRebootModal(false)}
        header="Restart device?"
        footer={
          <Box float="right">
            <SpaceBetween direction="horizontal" size="xs">
              <Button variant="link" onClick={() => setRebootModal(false)}>
                Cancel
              </Button>
              <Button variant="primary" onClick={doReboot}>
                Restart
              </Button>
            </SpaceBetween>
          </Box>
        }
      >
        This will reboot the Raspberry Pi. The drives will be temporarily unavailable to the car.
      </Modal>
    </ContentLayout>
  );
}
