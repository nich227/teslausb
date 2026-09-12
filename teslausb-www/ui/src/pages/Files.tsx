import { useEffect, useRef, useState } from 'react';
import ContentLayout from '@cloudscape-design/components/content-layout';
import Header from '@cloudscape-design/components/header';
import Container from '@cloudscape-design/components/container';
import Table from '@cloudscape-design/components/table';
import Button from '@cloudscape-design/components/button';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Box from '@cloudscape-design/components/box';
import BreadcrumbGroup from '@cloudscape-design/components/breadcrumb-group';
import SegmentedControl from '@cloudscape-design/components/segmented-control';
import Link from '@cloudscape-design/components/link';
import * as api from '../api';
import { Config, LsEntry } from '../api';
import { spaceString } from '../format';

export default function Files({ config }: { config: Config | null }) {
  const drives = [
    ...(config?.has_music === 'yes' ? [{ id: 'fs/Music', text: 'Music' }] : []),
    ...(config?.has_lightshow === 'yes' ? [{ id: 'fs/LightShow', text: 'LightShow' }] : []),
    ...(config?.has_boombox === 'yes' ? [{ id: 'fs/Boombox', text: 'Boombox' }] : []),
  ];
  const [root, setRoot] = useState(drives[0]?.id ?? 'fs/Music');
  const [path, setPath] = useState('');
  const [entries, setEntries] = useState<LsEntry[]>([]);
  const [selected, setSelected] = useState<LsEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  async function load() {
    setLoading(true);
    try {
      const res = await api.ls(root, path);
      setEntries(res.entries);
      setSelected([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [root, path]);

  const fullPath = (e: LsEntry) =>
    `${root}/${path ? path + '/' : ''}${e.name}`.replace(/\/+/g, '/');

  function openDir(e: LsEntry) {
    setPath(path ? `${path}/${e.name}` : e.name);
  }

  const crumbs = [
    { text: drives.find((d) => d.id === root)?.text ?? root, href: '' },
    ...path
      .split('/')
      .filter(Boolean)
      .map((seg, i, arr) => ({ text: seg, href: arr.slice(0, i + 1).join('/') })),
  ];

  return (
    <ContentLayout
      header={
        <Header variant="h1" description="Manage files on the music / lightshow / boombox drives">
          Files
        </Header>
      }
    >
      <Container
        header={
          <Header
            variant="h2"
            actions={
              <SpaceBetween direction="horizontal" size="xs">
                <Button iconName="refresh" loading={loading} onClick={load}>
                  Refresh
                </Button>
                <Button
                  iconName="folder"
                  onClick={async () => {
                    const name = prompt('New folder name');
                    if (name) {
                      await api.mkdir(`${root}/${path ? path + '/' : ''}${name}`);
                      load();
                    }
                  }}
                >
                  New folder
                </Button>
                <Button iconName="upload" onClick={() => fileInput.current?.click()}>
                  Upload
                </Button>
                <Button
                  iconName="download"
                  disabled={selected.length === 0 || selected.some((e) => e.type === 'dir')}
                  onClick={() =>
                    selected.forEach((e) => window.open(api.downloadUrl(fullPath(e)), '_blank'))
                  }
                >
                  Download
                </Button>
                <Button
                  iconName="remove"
                  disabled={selected.length === 0}
                  onClick={async () => {
                    if (confirm(`Delete ${selected.length} item(s)?`)) {
                      for (const e of selected) await api.rm(fullPath(e));
                      load();
                    }
                  }}
                >
                  Delete
                </Button>
              </SpaceBetween>
            }
          >
            {drives.length > 1 && (
              <SegmentedControl
                selectedId={root}
                onChange={(e) => {
                  setPath('');
                  setRoot(e.detail.selectedId);
                }}
                options={drives}
              />
            )}
          </Header>
        }
      >
        <SpaceBetween size="s">
          <BreadcrumbGroup
            items={crumbs}
            onFollow={(e) => {
              e.preventDefault();
              setPath(e.detail.href);
            }}
          />
          <Table
            variant="embedded"
            loading={loading}
            selectionType="multi"
            selectedItems={selected}
            onSelectionChange={(e) => setSelected(e.detail.selectedItems)}
            items={entries}
            trackBy="path"
            empty={
              <Box textAlign="center" color="inherit">
                No files
              </Box>
            }
            columnDefinitions={[
              {
                id: 'name',
                header: 'Name',
                cell: (e) =>
                  e.type === 'dir' ? (
                    <Link onFollow={() => openDir(e)}>📁 {e.name}</Link>
                  ) : (
                    <span>📄 {e.name}</span>
                  ),
                sortingField: 'name',
              },
              {
                id: 'size',
                header: 'Size',
                cell: (e) => (e.type === 'file' && e.size != null ? spaceString(e.size) : ''),
              },
            ]}
          />
        </SpaceBetween>
      </Container>
      <input
        ref={fileInput}
        type="file"
        multiple
        style={{ display: 'none' }}
        onChange={async (ev) => {
          const files = ev.target.files;
          if (!files) return;
          for (const f of Array.from(files)) await api.uploadFile(`${root}/${path}`, f);
          ev.target.value = '';
          load();
        }}
      />
    </ContentLayout>
  );
}
