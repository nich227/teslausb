import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, act, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import UpdateNotice from './UpdateNotice';
import * as api from '../api';
import type { UpdateState, Status } from '../api';
import { disableMotion } from '@cloudscape-design/global-styles';

// Flashbar animates an item out before removing it, and jsdom never finishes the
// transition, so a dismissed or replaced banner would linger in every assertion.
disableMotion(true);

vi.mock('../api', () => ({
  getUpdateStatus: vi.fn(),
  startUpdate: vi.fn(),
  getStatus: vi.fn(),
}));

const getUpdateStatus = vi.mocked(api.getUpdateStatus);
const startUpdate = vi.mocked(api.startUpdate);
const getStatus = vi.mocked(api.getStatus);

const offered: UpdateState = {
  checked: '2026-10-16T10:00:00-07:00',
  current: '1111111111111111111111111111111111111111',
  latest: 'v6.2',
  name: 'teslausb-20261020.1',
  url: 'https://github.com/nich227/teslausb/releases/tag/v6.2',
  available: true,
};

const status = (uptime: number) => ({ uptime }) as Status;

// Cloudscape's Modal always renders, hidden by a class; jsdom has no stylesheet,
// so open is told apart by that class rather than by presence.
const modalOpen = () => {
  const d = document.querySelector('[role=dialog]') as HTMLElement | null;
  return d !== null && !/awsui_hidden/.test(d.className);
};

async function renderSettled() {
  render(<UpdateNotice />);
  await act(async () => {});
}

beforeEach(() => {
  sessionStorage.clear();
  vi.clearAllMocks();
  getStatus.mockResolvedValue(status(1000));
});

describe('UpdateNotice', () => {
  it('shows nothing before the boot check has an answer', async () => {
    getUpdateStatus.mockResolvedValue({ state: null, running: false });
    await renderSettled();
    expect(screen.queryByText(/is available/)).not.toBeInTheDocument();
  });

  it('shows nothing when the latest release is not newer', async () => {
    getUpdateStatus.mockResolvedValue({ state: { ...offered, available: false }, running: false });
    await renderSettled();
    expect(screen.queryByText(/is available/)).not.toBeInTheDocument();
  });

  it('offers a newer release, with its notes and the installed commit', async () => {
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    await renderSettled();
    expect(screen.getByText('teslausb v6.2 is available')).toBeInTheDocument();
    expect(screen.getByText(/This device runs 1111111\./)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Release notes/ })).toHaveAttribute(
      'href',
      offered.url,
    );
    expect(screen.getByRole('button', { name: 'Update now' })).toBeInTheDocument();
  });

  it('stays dismissed for that release, but not for a later one', async () => {
    const user = userEvent.setup();
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    const { unmount } = render(<UpdateNotice />);
    await act(async () => {});
    await user.click(screen.getByRole('button', { name: 'Dismiss' }));
    expect(screen.queryByText('teslausb v6.2 is available')).not.toBeInTheDocument();
    unmount();

    await renderSettled();
    expect(screen.queryByText('teslausb v6.2 is available')).not.toBeInTheDocument();

    getUpdateStatus.mockResolvedValue({ state: { ...offered, latest: 'v6.3' }, running: false });
    await renderSettled();
    expect(screen.getByText('teslausb v6.3 is available')).toBeInTheDocument();
  });

  it('asks before updating, and does nothing if cancelled', async () => {
    const user = userEvent.setup();
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    await renderSettled();
    await user.click(screen.getByRole('button', { name: 'Update now' }));
    expect(modalOpen()).toBe(true);
    expect(screen.getByRole('dialog')).toHaveTextContent(/unavailable to the car/);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    expect(modalOpen()).toBe(false);
    expect(startUpdate).not.toHaveBeenCalled();
  });

  it('starts the update when confirmed and shows it running', async () => {
    const user = userEvent.setup();
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    startUpdate.mockResolvedValue({ started: true });
    await renderSettled();
    await user.click(screen.getByRole('button', { name: 'Update now' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Update' }));
    expect(startUpdate).toHaveBeenCalledTimes(1);
    expect(screen.getByText('Updating to v6.2')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'setup log' })).toHaveAttribute('href', '#/logs');
    expect(modalOpen()).toBe(false);
  });

  it('shows why the device refused, and keeps the offer', async () => {
    const user = userEvent.setup();
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    startUpdate.mockResolvedValue({
      started: false,
      reason: 'an archive is running; try again when it finishes',
    });
    await renderSettled();
    await user.click(screen.getByRole('button', { name: 'Update now' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Update' }));
    expect(screen.getByText(/an archive is running/)).toBeInTheDocument();
    expect(modalOpen()).toBe(true);
    expect(screen.queryByText('Updating to v6.2')).not.toBeInTheDocument();
  });

  it('picks up an update already running when the page is opened', async () => {
    getUpdateStatus.mockResolvedValue({ state: offered, running: true });
    await renderSettled();
    expect(screen.getByText('Updating to v6.2')).toBeInTheDocument();
  });
});

describe('UpdateNotice while an update runs', () => {
  const reload = vi.fn();
  const realLocation = window.location;

  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...realLocation, reload },
    });
    reload.mockClear();
  });

  afterEach(() => {
    vi.useRealTimers();
    Object.defineProperty(window, 'location', { configurable: true, value: realLocation });
  });

  async function startRunning() {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    startUpdate.mockResolvedValue({ started: true });
    await renderSettled();
    await user.click(screen.getByRole('button', { name: 'Update now' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Update' }));
    getUpdateStatus.mockResolvedValue({ state: offered, running: true });
  }

  it('rides out the device going away while setup reinstalls the web server', async () => {
    await startRunning();
    getStatus.mockRejectedValue(new Error('network'));
    await act(() => vi.advanceTimersByTimeAsync(60_000));
    expect(screen.getByText('Updating to v6.2')).toBeInTheDocument();
    expect(reload).not.toHaveBeenCalled();
  });

  it('reloads once the device is back on a new boot', async () => {
    await startRunning();
    getStatus.mockResolvedValue(status(1200));
    await act(() => vi.advanceTimersByTimeAsync(5_000));
    expect(reload).not.toHaveBeenCalled();
    getStatus.mockResolvedValue(status(40));
    getUpdateStatus.mockResolvedValue({ state: null, running: false });
    await act(() => vi.advanceTimersByTimeAsync(5_000));
    expect(reload).toHaveBeenCalled();
  });

  it('does not call a briefly idle unit a failure', async () => {
    // The unit ends a few seconds before the reboot takes nginx down.
    await startRunning();
    getStatus.mockResolvedValue(status(1300));
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    await act(() => vi.advanceTimersByTimeAsync(10_000));
    expect(screen.queryByText(/stopped before it finished/)).not.toBeInTheDocument();
  });

  it('reports a failure when the unit stops and the device never reboots', async () => {
    await startRunning();
    getStatus.mockResolvedValue(status(1300));
    getUpdateStatus.mockResolvedValue({ state: offered, running: false });
    await act(() => vi.advanceTimersByTimeAsync(35_000));
    expect(screen.getByText('The update stopped before it finished')).toBeInTheDocument();
    expect(screen.queryByText('Updating to v6.2')).not.toBeInTheDocument();
    expect(reload).not.toHaveBeenCalled();
  });
});
