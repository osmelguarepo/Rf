#!/usr/bin/env python3
"""Download the third-party source art into assets/source/ and check each file's SHA-256.

A changed download fails loudly, so the slicer never runs on a sheet it was not written for.

    python3 tools/fetch_assets.py

Standard library only. urllib reads HTTPS_PROXY / https_proxy from the environment; behind a proxy with its own
certificate authority, point SSL_CERT_FILE at that CA bundle.
Next step: python3 tools/slice-sheet.py (see ASSETS.md).

Port of scripts/fetch-assets.mjs from the Phaser version (commit 0a0841f), with the same pinned hash and behaviour.
"""

from __future__ import annotations

import hashlib
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / "assets" / "source"
TIMEOUT_SECONDS = 60


@dataclass(frozen=True)
class Source:
    name: str
    url: str
    file: str
    sha256: str


SOURCES = [
    Source(
        name='GrafxKid "TD racing assets" (CC0), https://opengameart.org/content/top-down-arcade-racing-game',
        url="https://opengameart.org/sites/default/files/TD%20racing%20assets.png",
        file="grafxkid-td-racing-assets.png",
        # Recorded after the first download on 2026-10-10. tools/slice-sheet.py pins the same value.
        sha256="cc07bc95ed84d60f74c5fda36d7477fde478f4e0b67dd78de38346cbc5852c66",
    ),
]


class FetchError(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "fuel-rivals-fetch-assets/1"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.read()
    except urllib.error.HTTPError as err:
        raise FetchError(f"download failed: {url}\n  HTTP {err.code} {err.reason}") from err
    except (urllib.error.URLError, OSError) as err:
        reason = getattr(err, "reason", err)
        proxied = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        hint = "\n  Behind a proxy with its own CA? Set SSL_CERT_FILE to its CA bundle." if proxied else ""
        raise FetchError(f"download failed: {url}\n  {reason}{hint}") from err


def fetch_one(source: Source) -> None:
    path = SOURCE_DIR / source.file
    if path.exists():
        existing = path.read_bytes()
        if sha256(existing) == source.sha256:
            print(f"ok (already present)  {source.file}  {len(existing)} bytes  sha256 {source.sha256}")
            return
        print(
            f"warning: {source.file} on disk does not match the pinned hash; removing it and downloading again",
            file=sys.stderr,
        )
        path.unlink()

    data = download(source.url)
    actual = sha256(data)
    if actual != source.sha256:
        raise FetchError(
            "\n".join(
                [
                    f"SHA-256 MISMATCH for {source.url}",
                    f"  expected {source.sha256}",
                    f"  actual   {actual}  ({len(data)} bytes)",
                    "  The file upstream has changed. Nothing was written. Check the new file by hand, re-check its",
                    "  licence, re-measure the sheet with tools/slice-sheet.py, then update the pinned hash in both",
                    "  scripts.",
                ]
            )
        )

    # Write to a temporary name first, so an interrupted run never leaves a partial file under the real name.
    tmp = path.with_name(f"{path.name}.part")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    print(f"ok (downloaded)       {source.file}  {len(data)} bytes  sha256 {actual}")


def main() -> int:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    failed = False
    for source in SOURCES:
        try:
            fetch_one(source)
        except FetchError as err:
            failed = True
            print(f"\nERROR: {err}\n", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
