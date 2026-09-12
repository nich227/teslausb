import { Suspense, lazy, useEffect, useState } from 'react';
import { Routes, Route, useNavigate, useLocation } from 'react-router-dom';
import AppLayout from '@cloudscape-design/components/app-layout';
import SideNavigation, { SideNavigationProps } from '@cloudscape-design/components/side-navigation';
import TeslaLogo from './components/TeslaLogo';
import SettingsMenu from './components/SettingsMenu';
import Spinner from '@cloudscape-design/components/spinner';
import Box from '@cloudscape-design/components/box';
import { applyMode, Mode } from '@cloudscape-design/global-styles';
import { getConfig, Config } from './api';
import { ThemeContext } from './theme';

const Dashboard = lazy(() => import('./pages/Dashboard'));
const Diagnostics = lazy(() => import('./pages/Diagnostics'));
const Logs = lazy(() => import('./pages/Logs'));
const Tools = lazy(() => import('./pages/Tools'));
const Files = lazy(() => import('./pages/Files'));
const Recordings = lazy(() => import('./pages/Recordings'));
const Viewer = lazy(() => import('./pages/Viewer'));

export default function App() {
  const navigate = useNavigate();
  const location = useLocation();
  const [config, setConfig] = useState<Config | null>(null);
  const [navOpen, setNavOpen] = useState(true);
  const [dark, setDark] = useState(() => localStorage.getItem('tu_dark') === '1');

  useEffect(() => {
    applyMode(dark ? Mode.Dark : Mode.Light);
    localStorage.setItem('tu_dark', dark ? '1' : '0');
  }, [dark]);

  useEffect(() => {
    getConfig()
      .then(setConfig)
      .catch(() => setConfig(null));
  }, []);

  const hasCam = config?.has_cam === 'yes';
  const numDrives =
    (config?.has_music === 'yes' ? 1 : 0) +
    (config?.has_lightshow === 'yes' ? 1 : 0) +
    (config?.has_boombox === 'yes' ? 1 : 0);

  const navItems: SideNavigationProps.Item[] = [
    { type: 'link', text: 'Dashboard', href: '#/' },
    { type: 'link', text: 'Diagnostics', href: '#/diagnostics' },
    { type: 'link', text: 'Logs', href: '#/logs' },
    { type: 'link', text: 'Tools', href: '#/tools' },
    ...(numDrives > 0
      ? [{ type: 'link', text: 'Files', href: '#/files' } as SideNavigationProps.Item]
      : []),
    ...(hasCam
      ? ([
          { type: 'divider' },
          { type: 'link', text: 'Recordings', href: '#/recordings' },
          { type: 'link', text: 'Camera Viewer', href: '#/viewer' },
        ] as SideNavigationProps.Item[])
      : []),
    { type: 'divider' },
    {
      type: 'link',
      text: 'TeslaUSB on GitHub',
      href: 'https://github.com/marcone/teslausb',
      external: true,
    },
  ];

  const activeHref = '#' + (location.pathname === '/' ? '/' : location.pathname);

  return (
    <ThemeContext.Provider value={dark}>
      <div id="top-nav" className="tu-header" style={{ background: dark ? '#161d26' : '#ffffff' }}>
        <div className="tu-header-side" />
        <div className="tu-header-center">
          <TeslaLogo darkMode={dark} />
        </div>
        <div className="tu-header-side tu-header-right">
          <SettingsMenu darkMode={dark} onDarkModeChange={setDark} />
        </div>
      </div>
      <AppLayout
        headerSelector="#top-nav"
        toolsHide
        navigationOpen={navOpen}
        onNavigationChange={(e) => setNavOpen(e.detail.open)}
        navigation={
          <SideNavigation
            activeHref={activeHref}
            header={{ href: '#/', text: 'TeslaUSB' }}
            items={navItems}
            onFollow={(e) => {
              if (!e.detail.external) {
                e.preventDefault();
                navigate(e.detail.href.replace(/^#/, ''));
              }
            }}
          />
        }
        content={
          <Suspense
            fallback={
              <Box textAlign="center" padding="xxl">
                <Spinner size="large" /> Loading…
              </Box>
            }
          >
            <Routes>
              <Route path="/" element={<Dashboard config={config} />} />
              <Route path="/diagnostics" element={<Diagnostics />} />
              <Route path="/logs" element={<Logs />} />
              <Route path="/tools" element={<Tools config={config} />} />
              <Route path="/files" element={<Files config={config} />} />
              <Route path="/recordings" element={<Recordings />} />
              <Route path="/viewer" element={<Viewer />} />
            </Routes>
          </Suspense>
        }
      />
    </ThemeContext.Provider>
  );
}
