import { defineConfig } from 'vitest/config';

// base './' keeps asset paths relative, so dist/ also works from file:// (needed for the later Electron build).
export default defineConfig({
  base: './',
  server: {
    port: 5173,
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  test: {
    include: ['tests/**/*.test.ts'],
  },
});
