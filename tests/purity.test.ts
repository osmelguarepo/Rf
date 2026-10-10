import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * The rules layer must stay engine-free so it can run in Node, in tests and in any wrapper.
 * Anything that touches Phaser, the DOM, wall-clock time or Math.random belongs outside src/game/.
 */
const FORBIDDEN = [/from ['"]phaser/, /window\./, /document\./, /Math\.random/, /Date\.now/, /performance\.now/];

const gameDir = join(fileURLToPath(new URL('..', import.meta.url)), 'src', 'game');
const files = readdirSync(gameDir).filter((name) => name.endsWith('.ts'));

describe('src/game purity', () => {
  it('scans the rules modules', () => {
    expect(files.length).toBeGreaterThan(5);
  });

  for (const name of files) {
    it(`${name} imports and calls nothing from the engine, DOM or clock`, () => {
      const text = readFileSync(join(gameDir, name), 'utf8');
      for (const pattern of FORBIDDEN) {
        expect(text, `matched ${pattern}`).not.toMatch(pattern);
      }
    });
  }
});
