#!/usr/bin/env python3
"""Generate an original procedural PNG app icon for AliceCradleLauncher (zero third-party assets)."""
from pathlib import Path
import argparse
import math
import struct
import zlib


def write_png(path: Path, width: int, height: int, rgba_rows: list[bytes]) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rgba_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def render_icon(size: int) -> list[bytes]:
    rows: list[bytes] = []
    cx = cy = (size - 1) / 2.0
    r_outer = size * 0.36
    r_inner = size * 0.25
    for y in range(size):
        row = bytearray(size * 4)
        ny = y / max(size - 1, 1)
        for x in range(size):
            nx = x / max(size - 1, 1)
            # Deep nocturnal violet-to-midnight gradient
            r = int(26 + 44 * (1.0 - ny) + 22 * nx)
            g = int(16 + 24 * (1.0 - ny) + 18 * (1.0 - nx))
            b = int(48 + 78 * (1.0 - ny) + 40 * nx)

            dx = x - cx
            dy = y - cy
            d = math.hypot(dx, dy)

            # Soft glowing cradle ring (crescent + orbital halo)
            ring = abs(d - r_outer)
            if ring < size * 0.045:
                t = max(0.0, 1.0 - ring / (size * 0.045))
                r = min(255, int(r + 175 * t))
                g = min(255, int(g + 130 * t))
                b = min(255, int(b + 245 * t))

            # Inner crescent moon offset
            d_moon = math.hypot(dx + size * 0.06, dy + size * 0.04)
            if d < r_inner and d_moon > r_inner * 0.82:
                r, g, b = 242, 232, 255

            # Four-point star accent
            sdx = abs(dx - size * 0.13)
            sdy = abs(dy + size * 0.14)
            star = (sdx * sdy) / max(size * size * 0.0014, 1.0)
            if star < 1.0 and (sdx + sdy) < size * 0.11:
                glow = 1.0 - star
                r = min(255, int(r + 220 * glow))
                g = min(255, int(g + 200 * glow))
                b = min(255, int(b + 255 * glow))

            idx = x * 4
            row[idx] = r
            row[idx + 1] = g
            row[idx + 2] = b
            row[idx + 3] = 255
        rows.append(bytes(row))
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate procedural launcher icons.")
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    for name, sz in [("AppIcon60x60@3x.png", 180), ("AppIcon1024.png", 1024)]:
        write_png(args.out_dir / name, sz, sz, render_icon(sz))
        print(f"Generated {args.out_dir / name} ({sz}x{sz})")


if __name__ == "__main__":
    main()
