import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/** The MVP ships with no audio at all: no audio APIs, no audio files, no sound manager. */
const FORBIDDEN = [
  /AudioContext/,
  /new\s+Audio\s*\(/,
  /HTMLAudioElement/,
  /\.(mp3|wav|ogg|m4a|flac|aac)\b/i,
  /this\.sound\b/,
  /SoundManager/,
  /howler/i,
];

function listFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name: string) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? listFiles(path) : [path];
  });
}

describe('no audio', () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  const files = [...listFiles(join(root, 'src')), join(root, 'index.html')];

  it('scans a non-empty set of source files', () => {
    expect(files.length).toBeGreaterThan(5);
  });

  for (const file of files) {
    it(`${file.replace(root, '')} contains no audio code`, () => {
      const text = readFileSync(file, 'utf8');
      for (const pattern of FORBIDDEN) {
        expect(text, `matched ${pattern}`).not.toMatch(pattern);
      }
    });
  }
});
