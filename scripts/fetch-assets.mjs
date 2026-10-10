#!/usr/bin/env node
/**
 * Downloads the third-party source art into assets/source/ and checks each file's SHA-256.
 * A changed download fails loudly, so the slicer never runs on a sheet it was not written for.
 *
 *   node scripts/fetch-assets.mjs
 *
 * Behind an HTTPS proxy, Node's fetch needs NODE_USE_ENV_PROXY=1 (Node 22.21 or later).
 * Next step: python3 scripts/slice-sheet.py (see ASSETS.md).
 */
import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SOURCE_DIR = join(ROOT, 'assets', 'source');

const SOURCES = [
  {
    name: 'GrafxKid "TD racing assets" (CC0), https://opengameart.org/content/top-down-arcade-racing-game',
    url: 'https://opengameart.org/sites/default/files/TD%20racing%20assets.png',
    file: 'grafxkid-td-racing-assets.png',
    // Recorded after the first download on 2026-10-10. scripts/slice-sheet.py pins the same value.
    sha256: 'cc07bc95ed84d60f74c5fda36d7477fde478f4e0b67dd78de38346cbc5852c66',
  },
];

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function readIfPresent(path) {
  try {
    return await readFile(path);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

async function download(url) {
  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  } catch (err) {
    const proxied = process.env.HTTPS_PROXY || process.env.https_proxy;
    const hint = proxied && process.env.NODE_USE_ENV_PROXY !== '1' ? '\n  Behind a proxy? Re-run with NODE_USE_ENV_PROXY=1.' : '';
    throw new Error(`download failed: ${url}\n  ${err.cause?.message ?? err.message}${hint}`);
  }
  if (!res.ok) throw new Error(`download failed: ${url}\n  HTTP ${res.status} ${res.statusText}`);
  return Buffer.from(await res.arrayBuffer());
}

async function fetchOne(source) {
  const path = join(SOURCE_DIR, source.file);
  const existing = await readIfPresent(path);
  if (existing && sha256(existing) === source.sha256) {
    console.log(`ok (already present)  ${source.file}  ${existing.length} bytes  sha256 ${source.sha256}`);
    return;
  }
  if (existing) {
    console.warn(`warning: ${source.file} on disk does not match the pinned hash; removing it and downloading again`);
    await rm(path);
  }

  const bytes = await download(source.url);
  const actual = sha256(bytes);
  if (actual !== source.sha256) {
    throw new Error(
      [
        `SHA-256 MISMATCH for ${source.url}`,
        `  expected ${source.sha256}`,
        `  actual   ${actual}  (${bytes.length} bytes)`,
        '  The file upstream has changed. Nothing was written. Check the new file by hand, re-check its licence,',
        '  re-measure the sheet with scripts/slice-sheet.py, then update the pinned hash in both scripts.',
      ].join('\n'),
    );
  }

  // Write to a temporary name first, so an interrupted run never leaves a partial file under the real name.
  const tmp = `${path}.part`;
  await writeFile(tmp, bytes);
  await rename(tmp, path);
  console.log(`ok (downloaded)       ${source.file}  ${bytes.length} bytes  sha256 ${actual}`);
}

await mkdir(SOURCE_DIR, { recursive: true });
let failed = false;
for (const source of SOURCES) {
  try {
    await fetchOne(source);
  } catch (err) {
    failed = true;
    console.error(`\nERROR: ${err.message}\n`);
  }
}
if (failed) process.exit(1);
