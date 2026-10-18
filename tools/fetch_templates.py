"""Installs the four Godot 4.7.2 export templates the builds need (docs/GODOT_PLAN.md §0, §6 B3).

    python3 -I tools/fetch_templates.py [DEST]

The official templates come as one 1.28 GB zip (Godot_v4.7.2-stable_export_templates.tpz). This script reads the zip's
directory with HTTP range requests and downloads only version.txt, linux_release.x86_64 and the two Windows release
executables (about 175 MB), checking each file's size and CRC-32 against the zip's directory. The release publishes a
SHA-512 for the whole .tpz only, so no per-file SHA-512 can be checked without the full download.
DEST defaults to Godot's template folder, ~/.local/share/godot/export_templates/4.7.2.stable. Files already there with
the right size and CRC-32 are kept. Exit codes: 0 done; 1 a download or check failed.
"""
import os, struct, sys, urllib.request, zlib

URL = "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
WANT = ["templates/version.txt", "templates/linux_release.x86_64",
        "templates/windows_release_x86_64.exe", "templates/windows_release_x86_64_console.exe"]
out = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.local/share/godot/export_templates/4.7.2.stable")

def get(start, end):
    req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req) as r:
        return r.read()

head = urllib.request.urlopen(urllib.request.Request(URL, method="HEAD"))
size = int(head.headers["Content-Length"])
tail = get(size - 65557, size - 1)
i = tail.rfind(b"PK\x05\x06")
_, _, _, _, n, cd_size, cd_off = struct.unpack("<IHHHHII", tail[i:i + 20])
if cd_off == 0xFFFFFFFF or n == 0xFFFF:  # zip64
    j = tail.rfind(b"PK\x06\x07")
    _, _, z64_off, _ = struct.unpack("<IIQI", tail[j:j + 20])
    rec = get(z64_off, z64_off + 55)
    n, cd_size, cd_off = struct.unpack("<QQQ", rec[32:56])
cd = get(cd_off, cd_off + cd_size - 1)
p = 0
entries = {}
for _ in range(n):
    (sig, _, _, _, method, _, _, crc, csize, usize, nlen, elen, clen, _, _, _, loff) = struct.unpack("<IHHHHHHIIIHHHHHII", cd[p:p + 46])
    name = cd[p + 46:p + 46 + nlen].decode()
    extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
    q = 0
    while q < len(extra):
        hid, hsz = struct.unpack("<HH", extra[q:q + 4])
        if hid == 1:
            vals = list(struct.unpack("<" + "Q" * (hsz // 8), extra[q + 4:q + 4 + hsz]))
            if usize == 0xFFFFFFFF: usize = vals.pop(0)
            if csize == 0xFFFFFFFF: csize = vals.pop(0)
            if loff == 0xFFFFFFFF: loff = vals.pop(0)
        q += 4 + hsz
    entries[name] = (method, crc, csize, usize, loff)
    p += 46 + nlen + elen + clen
print(f"tpz {size} bytes, {n} entries")
os.makedirs(out, exist_ok=True)
for name in WANT:
    method, crc, csize, usize, loff = entries[name]
    dest = os.path.join(out, os.path.basename(name))
    if os.path.exists(dest) and os.path.getsize(dest) == usize and zlib.crc32(open(dest, "rb").read()) & 0xFFFFFFFF == crc:
        print(f"{name}: already there, crc32 {crc:08x} ok")
        continue
    lh = get(loff, loff + 29)
    nlen, elen = struct.unpack("<HH", lh[26:30])
    start = loff + 30 + nlen + elen
    data = get(start, start + csize - 1)
    if method == 8:
        data = zlib.decompress(data, -15)
    assert len(data) == usize, name
    assert zlib.crc32(data) & 0xFFFFFFFF == crc, f"CRC mismatch {name}"
    open(dest, "wb").write(data)
    print(f"{name}: {usize} bytes, crc32 {crc:08x} ok")
