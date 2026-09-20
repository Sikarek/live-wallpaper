#!/usr/bin/env python3
"""
starbound_unpack.py — list or extract files from a Starbound SBAsset6 pack (packed.pak).

Why this exists: LiveWallpaper can use any image/video/HTML you own. The Starbound
loading-screen art is copyrighted by Chucklefish, so it is NOT shipped in this repo.
This tool pulls it out of the copy of Starbound already installed on your machine.

    python3 tools/starbound_unpack.py --list 'title|loading'
    python3 tools/starbound_unpack.py --extract 'title/.*\\.png' --out wallpapers/starbound

Pack format (reverse engineered from packed.pak):
    "SBAsset6"          8 bytes magic
    uint64 BE           offset of the index block
    ...                 file contents ...
    @index_offset:      "INDEX" + SBON metadata (author/name/priority/friendlyName)
                        + varint file count
                        + count x { varint path_length, path bytes, uint64 BE offset, uint64 BE size }

No dependencies. Reads only the index for --list (~ms even on a 900 MB pak).
"""
import argparse
import os
import re
import struct
import sys

DEFAULT_PAKS = [
    "~/Library/Application Support/Steam/steamapps/common/Starbound/assets/packed.pak",
    "~/.steam/steam/steamapps/common/Starbound/assets/packed.pak",
    "~/.local/share/Steam/steamapps/common/Starbound/assets/packed.pak",
    "C:/Program Files (x86)/Steam/steamapps/common/Starbound/assets/packed.pak",
]


def find_pak(explicit=None):
    if explicit:
        return os.path.expanduser(explicit)
    for c in DEFAULT_PAKS:
        p = os.path.expanduser(c)
        if os.path.isfile(p):
            return p
    sys.exit("no packed.pak found — pass one explicitly: --pak /path/to/packed.pak")


def read_varint(buf, pos):
    """Starbound varint: 7 bits per byte, high bit = continuation, big-endian order."""
    val = 0
    while True:
        b = buf[pos]
        pos += 1
        val = (val << 7) | (b & 0x7F)
        if not (b & 0x80):
            return val, pos


def parse_index(pak_path):
    """Return (list of (path, offset, size))."""
    size = os.path.getsize(pak_path)
    with open(pak_path, "rb") as f:
        magic = f.read(8)
        if magic != b"SBAsset6":
            sys.exit(f"not an SBAsset6 pack (magic = {magic!r})")
        index_off = struct.unpack(">Q", f.read(8))[0]
        f.seek(index_off)
        head = f.read(4096)
    if not head.startswith(b"INDEX"):
        sys.exit("index block not found at the advertised offset")

    # The INDEX block starts with a small SBON metadata document whose length is not
    # declared, so instead of implementing SBON we try every plausible entry start and
    # keep the one whose walk consumes the rest of the file cleanly.
    base = index_off
    for probe in range(base + 5, base + 260):
        entries = try_walk(pak_path, probe, size)
        if entries:
            return entries
    sys.exit("could not parse the index")


def try_walk(pak_path, start, file_size):
    entries = []
    with open(pak_path, "rb") as f:
        f.seek(start)
        # read in chunks: index is a few MB
        buf = f.read(file_size - start)
    pos = 0
    try:
        count, pos = read_varint(buf, pos)
        if not (0 < count < 5_000_000):
            return None
        for _ in range(count):
            plen, pos = read_varint(buf, pos)
            if not (0 < plen < 4096) or buf[pos:pos + 1] != b"/":
                return None
            path = buf[pos:pos + plen].decode("utf-8", "replace")
            pos += plen
            off, sz = struct.unpack_from(">QQ", buf, pos)
            pos += 16
            if off + sz > file_size or off < 8:
                return None
            entries.append((path, off, sz))
    except (IndexError, struct.error):
        return None
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pak", help="path to packed.pak (auto-detected if omitted)")
    ap.add_argument("--list", metavar="REGEX", help="list matching asset paths")
    ap.add_argument("--extract", metavar="REGEX", help="extract matching assets")
    ap.add_argument("--out", default="wallpapers/starbound", help="output dir for --extract")
    ap.add_argument("--limit", type=int, default=0, help="stop after N matches (0 = all)")
    args = ap.parse_args()

    pak = find_pak(args.pak)
    print(f"# pak: {pak}")
    entries = parse_index(pak)
    print(f"# {len(entries)} assets in index")

    rx = re.compile(args.list or args.extract or ".*")
    hits = [(p, o, s) for p, o, s in entries if rx.search(p)]
    if args.limit:
        hits = hits[:args.limit]

    if args.list or not args.extract:
        for p, o, s in hits:
            print(f"{s:>10}  {p}")
        print(f"# {len(hits)} match(es)")
        return

    out_root = os.path.expanduser(args.out)
    with open(pak, "rb") as f:
        for p, o, s in hits:
            dest = os.path.join(out_root, p.lstrip("/"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            f.seek(o)
            with open(dest, "wb") as g:
                g.write(f.read(s))
            print(f"extracted {s:>9} bytes -> {dest}")
    print(f"# {len(hits)} file(s) -> {out_root}")


if __name__ == "__main__":
    main()
