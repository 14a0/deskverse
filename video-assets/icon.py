"""Deskverse icon: the three desks seen through the black hole, the blue desk bent into a ring around it.

Rendered with the same lens as the video (blackhole.lensed), then set in a macOS icon tile.
Usage: python3 icon.py <out_dir> [t ...]   t in 0..1 is how far the desks have fallen (default 0.62 0.72 0.82)
"""
import sys

import numpy as np
from PIL import Image, ImageDraw

import blackhole as bh
import title


def render(t, size=1024):
    src = title.desks_image()
    shadow = 330 * t
    frame = bh.lensed(src, shadow / 0.55 * (0.35 + 0.65 * t), shadow, twist=1.1 * t)
    # Square crop around the hole, wide enough to hold the ring.
    half = int(max(shadow * 2.1, 200))
    cx, cy = bh.W // 2, bh.H // 2
    crop = Image.fromarray(frame[cy - half:cy + half, cx - half:cx + half].clip(0, 255).astype(np.uint8))
    tile_size = round(size * 824 / 1024)
    art = crop.resize((tile_size, tile_size), Image.LANCZOS)
    # macOS tile: 824 of 1024, corner radius about 22.5% of the tile, near-black ground.
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile = Image.new("RGBA", (tile_size, tile_size), (11, 11, 13, 255))
    tile.paste(art, (0, 0))
    mask = Image.new("L", (tile_size, tile_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tile_size - 1, tile_size - 1], radius=round(tile_size * 0.225), fill=255)
    offset = (size - tile_size) // 2
    icon.paste(tile, (offset, offset), mask)
    return icon


if __name__ == "__main__":
    out = sys.argv[1]
    ts = [float(x) for x in sys.argv[2:]] or [0.62, 0.72, 0.82]
    for t in ts:
        render(t).save(f"{out}/deskverse-icon-t{t:.2f}.png")
        print("wrote", t)
