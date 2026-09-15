import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import SettingsMenu from './SettingsMenu';

// Regression cover for the settings panel appearing behind the hamburger bar on
// narrow viewports. It used a Cloudscape Popover, which renders inline inside the
// header; the header is z-index 1000 and so are Cloudscape's own
// .awsui_mobile-bar and .awsui_mobile-toolbar, which AppLayout renders after it in
// the DOM. With equal z-index, DOM order decides, so the toolbar painted over the
// popover. Desktops have no mobile toolbar and never showed it. A Modal renders in
// a portal instead, which is what the "outside the header" case below pins down.
//
// Open and closed cannot be told apart by whether the dialog is in the document:
// Cloudscape's Modal always renders its content and its role=dialog, and hides it
// with CSS. These tests run in jsdom without Cloudscape's stylesheet, so nothing
// is really hidden. The state marker is a class on the dialog root, matched on the
// stable prefix because the hash suffix changes between Cloudscape versions.
const dialogRoot = () => document.querySelector('[role=dialog]') as HTMLElement | null;
const isOpen = () => {
  const d = dialogRoot();
  return d !== null && !/awsui_hidden/.test(d.className);
};

describe('SettingsMenu', () => {
  it('starts closed', () => {
    render(<SettingsMenu darkMode={false} onDarkModeChange={() => {}} />);
    expect(screen.getByLabelText('Open settings')).toBeInTheDocument();
    expect(isOpen()).toBe(false);
  });

  it('opens a dialog when the trigger is pressed', async () => {
    const user = userEvent.setup();
    render(<SettingsMenu darkMode={false} onDarkModeChange={() => {}} />);
    await user.click(screen.getByLabelText('Open settings'));

    expect(isOpen()).toBe(true);
    expect(dialogRoot()).toHaveTextContent('Settings');
  });

  it('renders the dialog outside the header, so header stacking cannot cover it', async () => {
    const user = userEvent.setup();
    // Reproduce the real arrangement: the menu sits inside the sticky header.
    render(
      <div className="tu-header" style={{ zIndex: 1000 }} data-testid="header">
        <SettingsMenu darkMode={false} onDarkModeChange={() => {}} />
      </div>,
    );
    await user.click(screen.getByLabelText('Open settings'));

    const dialog = dialogRoot();
    expect(dialog).not.toBeNull();
    expect(screen.getByTestId('header').contains(dialog)).toBe(false);
  });

  it('reports dark mode changes from the toggle', async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<SettingsMenu darkMode={false} onDarkModeChange={onChange} />);
    await user.click(screen.getByLabelText('Open settings'));
    await user.click(screen.getByText('Dark Mode'));

    expect(onChange).toHaveBeenCalledWith(true);
  });

  it('reflects the current dark mode in the toggle', async () => {
    const user = userEvent.setup();
    render(<SettingsMenu darkMode={true} onDarkModeChange={() => {}} />);
    await user.click(screen.getByLabelText('Open settings'));

    expect(screen.getByRole('checkbox')).toBeChecked();
  });

  it('closes again when dismissed', async () => {
    const user = userEvent.setup();
    render(<SettingsMenu darkMode={false} onDarkModeChange={() => {}} />);
    await user.click(screen.getByLabelText('Open settings'));
    expect(isOpen()).toBe(true);

    await user.click(screen.getByText('Done'));
    expect(isOpen()).toBe(false);
  });
});
