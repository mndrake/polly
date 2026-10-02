#!/usr/bin/env python3
"""Renders App/Icon/AppIcon.svg into App/Icon/AppIcon-1024.png and App/AppIcon.icns.

Requires: pip install pillow resvg-py
The .icns is committed, so building the app doesn't need these tools.
"""
import io
import struct
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "App/Icon/AppIcon.svg"
PNG = ROOT / "App/Icon/AppIcon-1024.png"
ICNS = ROOT / "App/AppIcon.icns"

# ICNS PNG entry types and their pixel sizes (1x and @2x variants).
ENTRIES = [
    ("icp4", 16), ("ic11", 32),    # 16pt, 16pt@2x
    ("icp5", 32), ("ic12", 64),    # 32pt, 32pt@2x
    ("ic07", 128), ("ic13", 256),  # 128pt, 128pt@2x
    ("ic08", 256), ("ic14", 512),  # 256pt, 256pt@2x
    ("ic09", 512), ("ic10", 1024), # 512pt, 512pt@2x
]


def render(size: int) -> bytes:
    # Render the vector at each size (sharper than downscaling one bitmap).
    png = bytes(resvg_py.svg_to_bytes(svg_string=SVG.read_text(), width=size, height=size))
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=True)
    return out.getvalue()


def main() -> None:
    PNG.write_bytes(render(1024))
    chunks = b""
    for kind, size in ENTRIES:
        data = render(size)
        chunks += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    ICNS.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
    print(f"wrote {PNG.relative_to(ROOT)} and {ICNS.relative_to(ROOT)} ({ICNS.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
