import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import TeslaTokenModal, { normaliseToken, getTeslaToken, setTeslaToken } from './TeslaTokenModal';

describe('normaliseToken', () => {
  // People copy whatever DevTools shows them; accept the common shapes rather than reject them.
  it('accepts a bare token', () => {
    expect(normaliseToken('  eyJabc.def.ghi  ')).toBe('eyJabc.def.ghi');
  });
  it('strips a copied header line', () => {
    expect(normaliseToken('Authorization: Bearer eyJabc.def.ghi')).toBe('eyJabc.def.ghi');
  });
  it('strips a bare Bearer prefix and quotes', () => {
    expect(normaliseToken('bearer "eyJabc.def.ghi"')).toBe('eyJabc.def.ghi');
  });
});

describe('token storage', () => {
  beforeEach(() => localStorage.clear());
  it('round-trips through localStorage and clears on empty', () => {
    setTeslaToken('tok');
    expect(getTeslaToken()).toBe('tok');
    setTeslaToken('');
    expect(getTeslaToken()).toBe('');
  });
});

describe('TeslaTokenModal', () => {
  beforeEach(() => localStorage.clear());

  it('links to Tesla and explains where the token comes from', () => {
    render(<TeslaTokenModal visible onDismiss={() => {}} onSaved={() => {}} />);
    const links = screen.getAllByRole('link', { name: /dashcam\.tesla\.com/ });
    expect(links.length).toBeGreaterThan(0);
    for (const l of links) expect(l).toHaveAttribute('href', 'https://dashcam.tesla.com');
    expect(screen.getByText(/Network/)).toBeInTheDocument();
    expect(screen.getByText(/Authorization: Bearer/)).toBeInTheDocument();
  });

  it('will not save an empty token', () => {
    render(<TeslaTokenModal visible onDismiss={() => {}} onSaved={() => {}} />);
    expect(screen.getByRole('button', { name: 'Save and play' })).toBeDisabled();
  });

  it('saves a normalised token and reports it', async () => {
    let saved = '';
    render(<TeslaTokenModal visible onDismiss={() => {}} onSaved={(t) => (saved = t)} />);
    await userEvent.type(screen.getByRole('textbox'), 'Bearer abc.def');
    await userEvent.click(screen.getByRole('button', { name: 'Save and play' }));
    expect(saved).toBe('abc.def');
    expect(getTeslaToken()).toBe('abc.def');
  });

  it('says so when it is being asked again because the last token expired', () => {
    render(<TeslaTokenModal visible expired onDismiss={() => {}} onSaved={() => {}} />);
    expect(screen.getByText(/did not accept the saved token/)).toBeInTheDocument();
  });

  it("is honest that this depends on how Tesla's site works today", () => {
    render(<TeslaTokenModal visible onDismiss={() => {}} onSaved={() => {}} />);
    expect(screen.getByText(/rather than on a documented interface/)).toBeInTheDocument();
  });
});
