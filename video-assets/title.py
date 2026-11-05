"""Title card: the three desks of the icon fall into a black hole; the ring stays; "Deskverse" appears.

Usage: python3 title.py <out.mp4> [name] [tagline]
"""
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import blackhole as bh

W, H, FPS = bh.W, bh.H, bh.FPS
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:
        # SF Pro's axes, in order: Width, Optical Size, GRAD, Weight.
        f.set_variation_by_axes([100, max(17, min(96, size)), 400, weight])
    except Exception:
        pass
    return f


def desks_image():
    """The icon's three desks, drawn flat on black at the centre: earlier desks graphite, the one you are on blue."""
    im = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(im)
    cw, ch, rad = 300, 190, 30
    cards = [((90, -90), (84, 84, 92)), ((45, -45), (140, 140, 148)), ((0, 0), (10, 132, 255))]
    for (ox, oy), color in cards:
        x0, y0 = W / 2 - cw / 2 - 45 + ox, H / 2 - ch / 2 + 45 + oy
        d.rounded_rectangle([x0, y0, x0 + cw, y0 + ch], radius=rad, fill=color)
    x0, y0 = W / 2 - cw / 2 - 45, H / 2 - ch / 2 + 45
    d.rounded_rectangle([x0 + 34, y0 + 52, x0 + 34 + 150, y0 + 52 + 20], radius=10, fill=(255, 255, 255))
    d.rounded_rectangle([x0 + 34, y0 + 90, x0 + 34 + 210, y0 + 90 + 20], radius=10, fill=(170, 205, 255))
    return np.asarray(im, dtype=np.float32)


def text_layer(name, tagline, alpha, ring_y):
    im = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(im)
    big, small = font(104, 600), font(34, 400)
    tw = d.textlength(name, font=big)
    d.text((W / 2 - tw / 2, ring_y + 120), name, font=big, fill=int(255 * alpha))
    sw = d.textlength(tagline, font=small)
    d.text((W / 2 - sw / 2, ring_y + 258), tagline, font=small, fill=int(150 * alpha))
    return np.asarray(im, dtype=np.float32)[..., None] / 255.0


def main(out_path, name="Deskverse", tagline="desktops from every parallel universe"):
    src = desks_image()
    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
         "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
         out_path],
        stdin=subprocess.PIPE,
    )
    black = np.zeros((H, W, 3), dtype=np.float32)

    def write(frame):
        ff.stdin.write(frame.clip(0, 255).astype(np.uint8).tobytes())

    for i in range(round(0.7 * FPS)):  # the desks appear
        write(src * bh.smoothstep(0, 1, (i + 1) / (0.45 * FPS)))
    n = round(1.1 * FPS)
    for i in range(n):  # they fall in: the hole grows past them
        t = bh.ease_in((i + 1) / n)
        shadow = 330 * t
        write(bh.lensed(src, shadow / 0.55 * (0.35 + 0.65 * t), shadow, twist=1.1 * t))
    n = round(0.6 * FPS)
    for i in range(n):  # the hole settles to a small, quiet ring
        t = bh.ease_out((i + 1) / n)
        shadow = 330 + (64 - 330) * t
        write(bh.lensed(black, shadow / 0.55, shadow, twist=0.0))
    ring_frame = bh.lensed(black, 64 / 0.55, 64, twist=0.0)
    n = round(0.9 * FPS)
    for i in range(round(2.4 * FPS)):  # the name, then hold
        a = bh.smoothstep(0, 1, (i + 1) / n)
        txt = text_layer(name, tagline, a, H / 2)
        # Move the ring up a little as the name arrives so the pair sits centred.
        shift = int(-110 * bh.ease_out(min(1.0, (i + 1) / n)))
        frame = np.roll(ring_frame, shift, axis=0)
        write(np.maximum(frame, 255 * np.roll(txt, shift, axis=0)))
    ff.stdin.close()
    ff.wait()


if __name__ == "__main__":
    main(*sys.argv[1:4])
