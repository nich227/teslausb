import { useState } from 'react';
import Box from '@cloudscape-design/components/box';
import Button from '@cloudscape-design/components/button';
import Modal from '@cloudscape-design/components/modal';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Toggle from '@cloudscape-design/components/toggle';

interface SettingsMenuProps {
  darkMode: boolean;
  onDarkModeChange: (checked: boolean) => void;
}

// A Modal rather than a Popover, because a Popover renders inline inside the
// header. The header is z-index 1000, and so are Cloudscape's own
// .awsui_mobile-bar and .awsui_mobile-toolbar, which AppLayout renders after it
// in the DOM. Equal z-index means DOM order decides, so on narrow viewports the
// popover appeared behind the hamburger bar. Desktops have no mobile toolbar and
// so never showed the problem. Modal renders in a portal well above both.
export default function SettingsMenu({ darkMode, onDarkModeChange }: SettingsMenuProps) {
  const [visible, setVisible] = useState(false);

  return (
    <>
      <Button
        iconName="settings"
        variant="inline-icon"
        ariaLabel="Open settings"
        onClick={() => setVisible(true)}
      />
      <Modal
        visible={visible}
        onDismiss={() => setVisible(false)}
        header="Settings"
        closeAriaLabel="Close settings"
        footer={
          <Box float="right">
            <Button variant="primary" onClick={() => setVisible(false)}>
              Done
            </Button>
          </Box>
        }
      >
        <SpaceBetween size="l" direction="vertical">
          <Toggle checked={darkMode} onChange={({ detail }) => onDarkModeChange(detail.checked)}>
            Dark Mode
          </Toggle>
          <Button iconName="refresh" onClick={() => window.location.reload()} fullWidth>
            Refresh Page
          </Button>
        </SpaceBetween>
      </Modal>
    </>
  );
}
