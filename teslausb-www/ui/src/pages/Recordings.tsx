import { useEffect, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import Table from '@cloudscape-design/components/table';
import Box from '@cloudscape-design/components/box';
import Link from '@cloudscape-design/components/link';
import Icon from '@cloudscape-design/components/icon';
import Button from '@cloudscape-design/components/button';
import Spinner from '@cloudscape-design/components/spinner';
import * as api from '../api';
import { LsEntry } from '../api';
import { spaceString } from '../format';

const ROOT = 'TeslaCam';

export default function Recordings() {
  const [top, setTop] = useState<LsEntry[]>([]);
  const [children, setChildren] = useState<Record<string, LsEntry[]>>({});
  const [expanded, setExpanded] = useState<LsEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingPaths, setLoadingPaths] = useState<Set<string>>(new Set());

  async function loadTop() {
    setLoading(true);
    try {
      const res = await api.ls(ROOT, '');
      setTop(sortEntries(res.entries));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadTop();
  }, []);

  function sortEntries(entries: LsEntry[]): LsEntry[] {
    return [...entries].sort((a, b) => {
      if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
      // newest-looking names first for dirs (dates), alpha for files
      return b.name.localeCompare(a.name);
    });
  }

  async function toggle(item: LsEntry, isExpanded: boolean) {
    if (!isExpanded) {
      setExpanded((prev) => prev.filter((i) => i.path !== item.path));
      return;
    }
    // Load children BEFORE marking the row expanded, so getItemChildren has data
    // to render the first time the table draws the expanded row.
    if (item.type === 'dir' && !children[item.path]) {
      setLoadingPaths((p) => new Set(p).add(item.path));
      try {
        const res = await api.ls(ROOT, item.path);
        setChildren((c) => ({ ...c, [item.path]: sortEntries(res.entries) }));
      } finally {
        setLoadingPaths((p) => {
          const n = new Set(p);
          n.delete(item.path);
          return n;
        });
      }
    }
    setExpanded((prev) => (prev.some((i) => i.path === item.path) ? prev : [...prev, item]));
  }

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Browse and download TeslaCam clips">
          Recordings
        </Header>
      }
    >
      <Table<LsEntry>
        variant="container"
        items={top}
        trackBy="path"
        loading={loading}
        loadingText="Loading recordings…"
        resizableColumns
        header={
          <Header
            actions={
              <Button iconName="refresh" onClick={loadTop}>
                Refresh
              </Button>
            }
          >
            TeslaCam
          </Header>
        }
        empty={
          <Box textAlign="center" color="inherit">
            No recordings found.
          </Box>
        }
        expandableRows={{
          getItemChildren: (item) => children[item.path] ?? [],
          isItemExpandable: (item) => item.type === 'dir',
          expandedItems: expanded,
          onExpandableItemToggle: ({ detail }) => toggle(detail.item, detail.expanded),
        }}
        columnDefinitions={[
          {
            id: 'name',
            header: 'Name',
            cell: (e) =>
              e.type === 'dir' ? (
                <span>
                  <Icon name="folder" /> {e.name}
                  {loadingPaths.has(e.path) ? (
                    <>
                      {'  '}
                      <Spinner size="normal" />
                    </>
                  ) : (
                    ''
                  )}
                </span>
              ) : (
                <span>
                  <Icon name="file" />{' '}
                  <Link href={`/${ROOT}/${e.path}`} external>
                    {e.name}
                  </Link>
                </span>
              ),
            isRowHeader: true,
          },
          {
            id: 'size',
            header: 'Size',
            cell: (e) => (e.type === 'file' && e.size != null ? spaceString(e.size) : ''),
            width: 120,
          },
          {
            id: 'actions',
            header: '',
            cell: (e) =>
              e.type === 'file' ? (
                <Button
                  variant="inline-icon"
                  iconName="download"
                  ariaLabel={`Download ${e.name}`}
                  href={`/${ROOT}/${e.path}`}
                  target="_blank"
                />
              ) : null,
            width: 70,
          },
        ]}
      />
    </ContentLayout>
  );
}
