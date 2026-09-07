#!/usr/bin/env python3
"""Read-only, complete BLOCK manifests for ZigCraft's region/chunk wire format.

Not a feature probe: every occupied location and all 65536 block bytes per
chunk are validated and hashed. Lighting, biomes, heightmaps and sector layout
are not block identity. Unknown formats fail closed; see chunk_serializer.zig
and region_file.zig when changing the wire format.
"""

import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zlib


def manifest(directory):
    chunks = {}
    regions = sorted(Path(directory).glob("r.*.*.mca"))
    if not regions:
        raise ValueError("no block regions")
    for path in regions:
        match = re.fullmatch(r"r\.(-?\d+)\.(-?\d+)\.mca", path.name)
        if not match or path.is_symlink() or not path.is_file():
            raise ValueError(f"invalid region: {path}")
        rx, rz = map(int, match.groups())
        data = path.read_bytes()
        if len(data) < 4096 or len(data) % 4096:
            raise ValueError(f"invalid region size: {path}")
        occupied = {0}
        for index in range(1024):
            location = int.from_bytes(data[index * 4:index * 4 + 4], "big")
            sector, count = location >> 8, location & 255
            if not location:
                continue
            key = f"{rx * 32 + index % 32},{rz * 32 + index // 32}"
            if not sector or not count or (sector + count) * 4096 > len(data):
                raise ValueError(f"invalid location: {path} chunk={key}")
            sectors = set(range(sector, sector + count))
            if occupied & sectors:
                raise ValueError(f"overlapping sectors: {path} chunk={key}")
            occupied.update(sectors)
            offset = sector * 4096
            length = int.from_bytes(data[offset:offset + 4], "big")
            if length < 2 or length + 4 > count * 4096 or data[offset + 4] != 2:
                raise ValueError(f"invalid compressed payload: {path} chunk={key}")
            decoder = zlib.decompressobj()
            # Bound expansion to the maximum supported chunk payload plus one.
            raw = decoder.decompress(data[offset + 5:offset + 4 + length], 197395)
            if not decoder.eof or decoder.unused_data or len(raw) < 18:
                raise ValueError(f"invalid zlib stream: {path} chunk={key}")
            magic, version, flags, crc, cx, cz = struct.unpack_from("<IBBIii", raw)
            expected = 18 + 65536 + bool(flags & 1) * 131072 + bool(flags & 2) * 256 + bool(flags & 4) * 512
            if magic != 0x5A434B00 or version not in (2, 3) or flags & 0xF0 or len(raw) != expected:
                raise ValueError(f"unsupported or malformed chunk: {path} chunk={key}")
            if f"{cx},{cz}" != key or zlib.crc32(raw[18:]) != crc or key in chunks:
                raise ValueError(f"coordinate/checksum/duplicate error: {path} chunk={key}")
            if flags & 2:
                biome_offset = 18 + 65536 + bool(flags & 1) * 131072
                # Serialized Biome IDs are contiguous 0..44 (world-core/block.zig).
                if any(biome > 44 for biome in raw[biome_offset:biome_offset + 256]):
                    raise ValueError(f"invalid biome data: {path} chunk={key}")
            chunks[key] = hashlib.sha256(raw[18:18 + 65536]).hexdigest()
    if not chunks:
        raise ValueError("no saved chunks")
    return {"format": "zigcraft-blocks-v1", "block_bytes_per_chunk": 65536, "chunks": chunks}


def compare(before, after):
    for value in (before, after):
        if value.get("format") != "zigcraft-blocks-v1" or value.get("block_bytes_per_chunk") != 65536 or not value.get("chunks"):
            raise ValueError("invalid block manifest")
    original, current = before["chunks"], after["chunks"]
    missing = sorted(original.keys() - current.keys())
    changed = sorted(key for key in original.keys() & current.keys() if original[key] != current[key])
    return {"original_chunks": len(original), "current_chunks": len(current),
            "added_chunks": sorted(current.keys() - original.keys()),
            "missing_chunks": missing, "changed_chunks": changed,
            "original_blocks_preserved": not missing and not changed}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "manifest":
        result = manifest(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        result = compare(*(json.loads(Path(path).read_text()) for path in sys.argv[2:]))
    else:
        raise ValueError("usage: canonical_saved_blocks.py manifest REGIONS | compare BEFORE.json AFTER.json")
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0 if result.get("original_blocks_preserved", True) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zlib.error) as error:
        print(f"Canonical saved block verification failed: {error}", file=sys.stderr)
        sys.exit(1)
