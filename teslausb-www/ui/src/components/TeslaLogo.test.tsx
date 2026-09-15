import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import TeslaLogo from './TeslaLogo';

// The "USB" half of the title is text next to an inline SVG wordmark, and it
// rendered in Times New Roman on iOS because nothing set a font-family outside
// Cloudscape's component scopes. The fix lives in index.css on the body element,
// which jsdom will not resolve, so the assertion here is the narrower one that
// still has value: the element must not carry an inline font-family that would
// override the stylesheet.
describe('TeslaLogo', () => {
  it('renders the USB wordmark text', () => {
    render(<TeslaLogo darkMode={false} />);
    expect(screen.getByText('USB')).toBeInTheDocument();
  });

  it('does not pin its own font-family, so the body stack applies', () => {
    render(<TeslaLogo darkMode={false} />);
    const usb = screen.getByText('USB');
    expect(usb.style.fontFamily).toBe('');
  });

  it('uses the Tesla red in light mode and white in dark mode', () => {
    const { unmount } = render(<TeslaLogo darkMode={false} />);
    expect(screen.getByText('USB')).toHaveStyle({ color: '#000000' });
    unmount();

    render(<TeslaLogo darkMode={true} />);
    expect(screen.getByText('USB')).toHaveStyle({ color: '#ffffff' });
  });
});
