import { useEffect, useRef, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import Container from '@cloudscape-design/components/container';
import SegmentedControl from '@cloudscape-design/components/segmented-control';
import Button from '@cloudscape-design/components/button';
import Toggle from '@cloudscape-design/components/toggle';
import SpaceBetween from '@cloudscape-design/components/space-between';
import * as api from '../api';
import { downloadText } from '../download';
import { logToUtc } from '../format';
import LogView from '../components/LogView';

const LOGS: Record<string, { file: string; label: string }> = {
  archiveloop: { file: 'archiveloop.log', label: 'Archiveloop log' },
  setup: { file: 'teslausb-headless-setup.log', label: 'Setup log' },
};

export default function Logs() {
  const [which, setWhich] = useState('archiveloop');
  const [text, setText] = useState('Loading…');
  const [auto, setAuto] = useState(true);
  const [loading, setLoading] = useState(true);
  const timer = useRef<number>();

  const cur = LOGS[which];

  async function load(showShimmer = false) {
    if (showShimmer) setLoading(true);
    try {
      const raw = (await api.readLog(cur.file)) || '(empty)';
      setText(logToUtc(raw));
    } catch {
      setText('(could not read log)');
    } finally {
      if (showShimmer) setLoading(false);
    }
  }

  // Show the shimmer only when switching logs (and on first load), not on polls.
  useEffect(() => {
    load(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [which]);

  useEffect(() => {
    window.clearInterval(timer.current);
    if (auto) timer.current = window.setInterval(() => load(false), 4000);
    return () => window.clearInterval(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [which, auto]);

  return (
    <ContentLayout header={<Header variant="h1" description="Live device logs">Logs</Header>}>
      <Container
        header={
          <Header
            variant="h2"
            actions={
              <SpaceBetween direction="horizontal" size="s">
                <Toggle checked={auto} onChange={(e) => setAuto(e.detail.checked)}>
                  Auto-refresh
                </Toggle>
                <Button iconName="refresh" onClick={() => load(true)}>
                  Refresh
                </Button>
                <Button iconName="download" onClick={() => downloadText(cur.file, text)}>
                  Download
                </Button>
              </SpaceBetween>
            }
          >
            <SegmentedControl
              selectedId={which}
              onChange={(e) => setWhich(e.detail.selectedId)}
              options={Object.entries(LOGS).map(([id, v]) => ({ id, text: v.label }))}
            />
          </Header>
        }
      >
        {loading ? (
          <div style={{ padding: 8 }}>
            {Array.from({ length: 14 }).map((_, i) => (
              <div
                key={i}
                className="tu-skel"
                style={{ height: 12, margin: '7px 0', width: `${45 + ((i * 13) % 50)}%`, borderRadius: 4 }}
              />
            ))}
          </div>
        ) : (
          <LogView text={text} autoscroll={auto} />
        )}
      </Container>
    </ContentLayout>
  );
}
