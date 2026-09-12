import { useEffect, useRef, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import Container from '@cloudscape-design/components/container';
import Button from '@cloudscape-design/components/button';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Box from '@cloudscape-design/components/box';
import * as api from '../api';
import { downloadText } from '../download';
import LogView from '../components/LogView';

export default function Diagnostics() {
  const [text, setText] = useState('Generating diagnostics…');
  const [running, setRunning] = useState(true);
  const inFlight = useRef(false);

  async function refresh() {
    // Don't start a new run if one is already in progress.
    if (inFlight.current) return;
    inFlight.current = true;
    setRunning(true);
    setText('Generating diagnostics…');
    try {
      setText((await api.runDiagnostics()) || 'No diagnostics output was produced.');
    } catch (e: any) {
      setText('Failed to generate diagnostics: ' + String(e?.message || e));
    } finally {
      setRunning(false);
      inFlight.current = false;
    }
  }

  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Generate and review device diagnostics">
          Diagnostics
        </Header>
      }
    >
      <Container
        header={
          <Header
            variant="h2"
            actions={
              <SpaceBetween direction="horizontal" size="xs">
                <Button iconName="refresh" loading={running} onClick={refresh}>
                  Refresh diagnostics
                </Button>
                <Button iconName="download" onClick={() => downloadText('diagnostics.txt', text)}>
                  Download
                </Button>
              </SpaceBetween>
            }
          >
            Output
          </Header>
        }
      >
        <Box>
          <LogView text={text} />
        </Box>
      </Container>
    </ContentLayout>
  );
}
