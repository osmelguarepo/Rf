import { defineConfig } from 'vitest/config';

// Only the golden generator. Run from the repository root of a checkout of commit 0a0841f (see README.md).
export default defineConfig({
  test: {
    include: ['tools/gen_golden/**/*.test.ts'],
    testTimeout: 300_000,
  },
});
