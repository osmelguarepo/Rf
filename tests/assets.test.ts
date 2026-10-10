import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { extname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Everything under public/ ships in dist/ (and later in the Electron build). Each file needs a licence record in
 * ASSETS.md, no audio may ship, and every atlas frame must lie inside the atlas image.
 */
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const PUBLIC = join(ROOT, 'public');
// Written without the leading dot, so the source scan in no-audio.test.ts would not flag this file.
const AUDIO_EXTENSIONS = ['mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac'];
const LICENCES = ['CC0-1.0', 'OFL-1.1', 'Own work'];

function listFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name: string) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? listFiles(path) : [path];
  });
}

/** Repo-relative path with forward slashes, as ASSETS.md writes it. */
function repoPath(path: string): string {
  return relative(ROOT, path).split(sep).join('/');
}

function cells(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim());
}

interface Row {
  file: string;
  licence: string;
  cells: string[];
}

/** Rows of the ASSETS.md table whose header starts with "File". */
function inventory(markdown: string): Row[] {
  const lines = markdown.split('\n');
  const start = lines.findIndex((line) => /^\|\s*File\s*\|/.test(line));
  if (start < 0) return [];
  const licenceColumn = cells(lines[start] ?? '').indexOf('Licence');
  const rows: Row[] = [];
  // Skip the header and the |---| separator, then read until the table ends.
  for (const line of lines.slice(start + 2)) {
    if (!line.trimStart().startsWith('|')) break;
    const row = cells(line);
    rows.push({ file: (row[0] ?? '').replace(/`/g, ''), licence: row[licenceColumn] ?? '', cells: row });
  }
  return rows;
}

/** Width and height from the IHDR chunk, which the PNG format requires to come first. */
function pngSize(png: Buffer): { width: number; height: number } {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (!png.subarray(0, 8).equals(signature) || png.toString('ascii', 12, 16) !== 'IHDR') {
    throw new Error('not a PNG file');
  }
  return { width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
}

/** A frame as read from sprites.json, before its fields are checked. */
type Frame = Record<'x' | 'y' | 'w' | 'h', unknown>;

function insideImage(frame: Frame, width: number, height: number): boolean {
  const values = [frame.x, frame.y, frame.w, frame.h];
  if (!values.every((v) => Number.isInteger(v))) return false;
  const [x, y, w, h] = values as number[];
  return w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= width && y + h <= height;
}

describe('shipped assets', () => {
  const shipped = existsSync(PUBLIC) ? listFiles(PUBLIC).map(repoPath) : [];

  it('scans a non-empty public/ folder', () => {
    expect(shipped.length).toBeGreaterThan(0);
  });

  it('public/ contains no audio files', () => {
    const audio = shipped.filter((file) => AUDIO_EXTENSIONS.includes(extname(file).slice(1).toLowerCase()));
    expect(audio).toEqual([]);
  });

  describe('ASSETS.md', () => {
    const rows = inventory(readFileSync(join(ROOT, 'ASSETS.md'), 'utf8'));

    it('has a file table', () => {
      expect(rows.length).toBeGreaterThan(0);
    });

    it('lists every file under public/', () => {
      const listed = new Set(rows.map((row) => row.file));
      expect(shipped.filter((file) => !listed.has(file))).toEqual([]);
    });

    it('lists only files that exist', () => {
      expect(rows.map((row) => row.file).filter((file) => !existsSync(join(ROOT, file)))).toEqual([]);
    });

    it('gives every file a source, author, use and a known licence', () => {
      const incomplete = rows.filter((row) => row.cells.length < 5 || row.cells.some((cell) => cell === ''));
      expect(incomplete.map((row) => row.file)).toEqual([]);
      const unknown = rows.filter((row) => !LICENCES.includes(row.licence));
      expect(unknown.map((row) => `${row.file}: ${row.licence}`)).toEqual([]);
    });
  });

  describe('sprite atlas', () => {
    const frames = JSON.parse(readFileSync(join(PUBLIC, 'assets', 'sprites.json'), 'utf8')) as Record<string, Frame>;
    const { width, height } = pngSize(readFileSync(join(PUBLIC, 'assets', 'sprites.png')));

    it('has frames', () => {
      expect(Object.keys(frames).length).toBeGreaterThan(0);
    });

    it('keeps every frame inside the atlas image', () => {
      const outside = Object.entries(frames).filter(([, frame]) => !insideImage(frame, width, height));
      expect(outside.map(([name, frame]) => `${name} ${JSON.stringify(frame)} in ${width}x${height}`)).toEqual([]);
    });
  });
});
