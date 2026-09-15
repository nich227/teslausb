import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Static SPA served by nginx on the Pi at "/". Relative base so assets resolve
// regardless of mount path. The heavy multi-cam Viewer is lazy-loaded (see
// App.tsx) so the dashboard loads fast on low-power clients.
export default defineConfig({
  base: '/',
  plugins: [react()],
  build: {
    outDir: 'dist',
    target: 'es2019',
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      output: {
        // vite 8 bundles with rolldown, which accepts only the function form of
        // manualChunks and rejects the object map rollup allowed ("manualChunks
        // is not a function"). Same two chunks as before: Cloudscape on its own,
        // and React with the router, so the dashboard's first paint does not pull
        // the whole component library.
        manualChunks(id) {
          if (id.includes('/node_modules/@cloudscape-design/')) {
            return 'cloudscape';
          }
          if (
            id.includes('/node_modules/react/') ||
            id.includes('/node_modules/react-dom/') ||
            id.includes('/node_modules/react-router') ||
            id.includes('/node_modules/scheduler/')
          ) {
            return 'react';
          }
          return undefined;
        },
      },
    },
  },
});
