import { useEffect, useRef, useState } from 'react';
import Flashbar, { FlashbarProps } from '@cloudscape-design/components/flashbar';
import Modal from '@cloudscape-design/components/modal';
import Box from '@cloudscape-design/components/box';
import Button from '@cloudscape-design/components/button';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Link from '@cloudscape-design/components/link';
import * as api from '../api';
import { UpdateState } from '../api';

// The boot check runs once and may take a while to reach GitHub, so a page opened
// soon after boot picks up its answer on a later poll.
const STATUS_POLL_MS = 60_000;
const PROGRESS_POLL_MS = 5_000;

type Phase = 'idle' | 'running' | 'failed';

// The upgrade restarts nginx partway and ends with a reboot, so the page cannot
// tell success from a dropped connection. Uptime can: it only goes backwards when
// the device has rebooted, which is the last thing a successful upgrade does.
export default function UpdateNotice() {
  const [state, setState] = useState<UpdateState | null>(null);
  const [phase, setPhase] = useState<Phase>('idle');
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [starting, setStarting] = useState(false);
  const [dismissed, setDismissed] = useState(
    () => sessionStorage.getItem('tu_update_dismissed') || '',
  );
  const startUptime = useRef(0);
  const idlePolls = useRef(0);

  useEffect(() => {
    const poll = () =>
      api
        .getUpdateStatus()
        .then(async (s) => {
          setState(s.state);
          if (s.running) {
            // A page opened mid-update still needs a baseline to spot the reboot.
            if (!startUptime.current) startUptime.current = (await api.getStatus()).uptime;
            setPhase('running');
          }
        })
        .catch(() => {});
    poll();
    const t = window.setInterval(poll, STATUS_POLL_MS);
    return () => window.clearInterval(t);
  }, []);

  useEffect(() => {
    if (phase !== 'running') return;
    idlePolls.current = 0;
    const t = window.setInterval(async () => {
      try {
        const [st, upd] = await Promise.all([api.getStatus(), api.getUpdateStatus()]);
        if (startUptime.current && st.uptime < startUptime.current) {
          window.location.reload();
        } else if (!upd.running) {
          // The unit ends a few seconds before the reboot takes nginx down, so one
          // idle answer is not a failure; half a minute of them, with the device
          // still up on the same boot, is.
          idlePolls.current += 1;
          if (idlePolls.current >= 6) setPhase('failed');
        } else {
          idlePolls.current = 0;
        }
      } catch {
        // nginx is down while setup reinstalls it, and during the reboot
      }
    }, PROGRESS_POLL_MS);
    return () => window.clearInterval(t);
  }, [phase]);

  async function onUpdate() {
    setStarting(true);
    setError(null);
    try {
      startUptime.current = (await api.getStatus()).uptime;
      const r = await api.startUpdate();
      if (r.started) {
        setPhase('running');
        setConfirm(false);
      } else {
        setError(r.reason || 'The device refused to start the update.');
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setStarting(false);
    }
  }

  const items: FlashbarProps.MessageDefinition[] = [];
  if (phase === 'running') {
    items.push({
      id: 'update-running',
      type: 'in-progress',
      loading: true,
      header: `Updating to ${state?.latest ?? 'the new release'}`,
      content: (
        <>
          This takes several minutes and ends with a reboot; the drives are unavailable to the car
          until then. The page reloads when the device is back. Progress is in the{' '}
          <Link href="#/logs">setup log</Link>.
        </>
      ),
    });
  } else if (phase === 'failed') {
    items.push({
      id: 'update-failed',
      type: 'error',
      header: 'The update stopped before it finished',
      content: (
        <>
          The device did not reboot into the new version. See the{' '}
          <Link href="#/logs">setup log</Link>, then restart the device from Tools.
        </>
      ),
      dismissible: true,
      dismissLabel: 'Dismiss',
      onDismiss: () => setPhase('idle'),
    });
  } else if (state?.available && dismissed !== state.latest) {
    items.push({
      id: 'update-available',
      type: 'info',
      header: `teslausb ${state.latest} is available`,
      content: (
        <>
          {state.name && `${state.name}. `}This device runs {state.current.slice(0, 7)}.{' '}
          {state.url && (
            <Link href={state.url} external>
              Release notes
            </Link>
          )}
        </>
      ),
      action: <Button onClick={() => setConfirm(true)}>Update now</Button>,
      dismissible: true,
      dismissLabel: 'Dismiss',
      onDismiss: () => {
        sessionStorage.setItem('tu_update_dismissed', state.latest);
        setDismissed(state.latest);
      },
    });
  }

  return (
    <>
      <Flashbar items={items} />
      <Modal
        visible={confirm}
        onDismiss={() => setConfirm(false)}
        header={`Update to ${state?.latest}?`}
        footer={
          <Box float="right">
            <SpaceBetween direction="horizontal" size="xs">
              <Button variant="link" onClick={() => setConfirm(false)}>
                Cancel
              </Button>
              <Button variant="primary" loading={starting} onClick={onUpdate}>
                Update
              </Button>
            </SpaceBetween>
          </Box>
        }
      >
        <SpaceBetween size="s">
          <Box>
            The device downloads {state?.latest}, reinstalls itself and reboots. The drives are
            unavailable to the car for the whole time, so do this parked, with the car kept awake
            and connected to Wi-Fi.
          </Box>
          {error && (
            <Box color="text-status-error" variant="p">
              {error}
            </Box>
          )}
        </SpaceBetween>
      </Modal>
    </>
  );
}
