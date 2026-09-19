import { useState } from 'react';
import Modal from '@cloudscape-design/components/modal';
import Box from '@cloudscape-design/components/box';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Button from '@cloudscape-design/components/button';
import FormField from '@cloudscape-design/components/form-field';
import Textarea from '@cloudscape-design/components/textarea';
import Link from '@cloudscape-design/components/link';
import Alert from '@cloudscape-design/components/alert';
import { TESLA_DASHCAM_URL } from '../teslaDecrypt';

// The token dashcam.tesla.com uses to ask Tesla for per-clip keys. It stays in this browser:
// it is kept in localStorage, sent only to Tesla, and never to the device. Anyone who can
// reach the device's web page could paste their own, which is no more than they could do at
// dashcam.tesla.com already.
const STORAGE_KEY = 'tu_tesla_token';

export function getTeslaToken(): string {
  return localStorage.getItem(STORAGE_KEY) || '';
}

export function setTeslaToken(token: string): void {
  if (token) localStorage.setItem(STORAGE_KEY, token);
  else localStorage.removeItem(STORAGE_KEY);
}

/**
 * Turns whatever was pasted into a bare token. People copy the whole header line, or the
 * value with quotes around it, and it is friendlier to accept those than to reject them.
 */
export function normaliseToken(pasted: string): string {
  return pasted
    .trim()
    .replace(/^authorization:\s*/i, '')
    .replace(/^bearer\s+/i, '')
    .replace(/^["']|["']$/g, '')
    .trim();
}

interface Props {
  visible: boolean;
  onDismiss: () => void;
  onSaved: (token: string) => void;
  /** Set when a previous token was rejected, so the modal can say why it is being asked again. */
  expired?: boolean;
}

export default function TeslaTokenModal({ visible, onDismiss, onSaved, expired }: Props) {
  const [value, setValue] = useState('');
  const token = normaliseToken(value);

  const save = () => {
    setTeslaToken(token);
    onSaved(token);
    setValue('');
  };

  return (
    <Modal
      visible={visible}
      onDismiss={onDismiss}
      header="Play encrypted clips"
      size="medium"
      footer={
        <Box float="right">
          <SpaceBetween direction="horizontal" size="xs">
            <Button variant="link" onClick={onDismiss}>
              Not now
            </Button>
            <Button variant="primary" onClick={save} disabled={!token}>
              Save and play
            </Button>
          </SpaceBetween>
        </Box>
      }
    >
      <SpaceBetween size="m">
        {expired && (
          <Alert type="warning">
            Tesla did not accept the saved token, which usually means it has expired. Paste a fresh
            one from the same page.
          </Alert>
        )}
        <Box variant="p">
          The car saved these clips with <strong>Encrypt Dashcam Recordings</strong> turned on.
          Tesla holds the keys, and hands them out to the account linked to the car. This viewer can
          fetch those keys the same way Tesla&apos;s own site does, and decrypt the video in your
          browser. The video and the keys never leave this browser, and nothing is sent to the
          teslausb device.
        </Box>
        <Box variant="p">To do that it needs the login token from Tesla&apos;s viewer:</Box>
        <ol style={{ margin: 0, paddingLeft: '1.4em' }}>
          <li>
            Open{' '}
            <Link href={TESLA_DASHCAM_URL} external externalIconAriaLabel="opens in a new tab">
              dashcam.tesla.com
            </Link>{' '}
            and sign in with the Tesla account the car is linked to.
          </li>
          <li>
            Open your browser&apos;s developer tools (<kbd>F12</kbd>, or <kbd>Cmd</kbd>+
            <kbd>Option</kbd>+<kbd>I</kbd> on a Mac) and choose the <strong>Network</strong> tab.
          </li>
          <li>
            Drop any encrypted clip onto the Tesla page so it makes a request, then click the
            request named <strong>batch</strong> (under <code>/api/1/decrypt/</code>).
          </li>
          <li>
            Under <strong>Request Headers</strong>, copy the value after{' '}
            <code>Authorization: Bearer</code> and paste it below. Pasting the whole line is fine
            too.
          </li>
        </ol>
        <FormField
          label="Tesla token"
          description="Kept in this browser only. Tesla expires these after a while, so you may be asked again."
        >
          <Textarea
            value={value}
            onChange={(e) => setValue(e.detail.value)}
            placeholder="eyJhbGciOi..."
            rows={3}
            spellcheck={false}
            ariaRequired
          />
        </FormField>
        <Box variant="small" color="text-body-secondary">
          This relies on how Tesla&apos;s viewer works today rather than on a documented interface,
          so it may stop working if Tesla changes their site. If it does, the clips are still
          archived and still open at{' '}
          <Link href={TESLA_DASHCAM_URL} external externalIconAriaLabel="opens in a new tab">
            dashcam.tesla.com
          </Link>
          .
        </Box>
      </SpaceBetween>
    </Modal>
  );
}
