"""Deskverse icon, clean version: a desk directly behind the black hole becomes an Einstein ring of its own light.

Usage: python3 icon_ring.py <out_dir>
"""
import sys

import numpy as np
from PIL import Image, ImageDraw

import blackhole as bh

BLUE = (10, 132, 255)
GRAPHITE = (110, 110, 118)


def source(cards):
    """cards: list of (offset_x, offset_y, width, height, colour, with_lines) drawn at the frame centre."""
    im = Image.new("RGB", (bh.W, bh.H), (0, 0, 0))
    d = ImageDraw.Draw(im)
    for ox, oy, w, h, color, lines in cards:
        x0, y0 = bh.W / 2 - w / 2 + ox, bh.H / 2 - h / 2 + oy
        d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=h * 0.16, fill=color)
        if lines:
            d.rounded_rectangle([x0 + w * 0.12, y0 + h * 0.3, x0 + w * 0.55, y0 + h * 0.3 + h * 0.1], radius=h * 0.05, fill=(255, 255, 255))
            d.rounded_rectangle([x0 + w * 0.12, y0 + h * 0.52, x0 + w * 0.72, y0 + h * 0.52 + h * 0.1], radius=h * 0.05, fill=(170, 205, 255))
    return np.asarray(im, dtype=np.float32)


def icon(src, theta_e, shadow, half, size=1024):
    frame = bh.lensed(src, theta_e, shadow, twist=0.0)
    cx, cy = bh.W // 2, bh.H // 2
    crop = Image.fromarray(frame[cy - half:cy + half, cx - half:cx + half].clip(0, 255).astype(np.uint8))
    tile_size = round(size * 824 / 1024)
    tile = Image.new("RGBA", (tile_size, tile_size), (11, 11, 13, 255))
    tile.paste(crop.resize((tile_size, tile_size), Image.LANCZOS), (0, 0))
    mask = Image.new("L", (tile_size, tile_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tile_size - 1, tile_size - 1], radius=round(tile_size * 0.225), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - tile_size) // 2
    out.paste(tile, (off, off), mask)
    return out


if __name__ == "__main__":
    out = sys.argv[1]
    variants = {
        "a-centred": [(0, 0, 260, 170, BLUE, True)],
        "b-with-graphite": [(70, -55, 260, 170, GRAPHITE, False), (0, 0, 260, 170, BLUE, True)],
        "c-offset": [(28, -18, 260, 170, BLUE, True)],
    }
    for name, cards in variants.items():
        icon(source(cards), theta_e=150, shadow=92, half=230).save(f"{out}/ring-{name}.png")
        print("wrote", name)
