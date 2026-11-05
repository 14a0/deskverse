"""Particle crossing: every particle is a real pixel of the desk.

The old desk dissolves into its own pixels, which spiral into a black hole (faster as they fall, like matter
on its way in) and vanish at the horizon. After a short dark beat, the new desk's pixels stream out of the
ring and settle into the new desk, which then resolves into the sharp screenshot.

Usage: python3 particles.py <old.png> <new.png> <out.mp4> [width]   (default width 3840, 16:9, 60 fps)
"""
import subprocess
import sys

import numpy as np
from PIL import Image

FPS = 60


def load(path, w, h):
    im = Image.open(path).convert("RGB")
    scale = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    left = (im.width - w) // 2
    return np.asarray(im.crop((left, 0, left + w, h)), dtype=np.float32)


def ease_in(t):
    return t ** 3


def ease_out(t):
    return 1 - (1 - t) ** 3


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


class Field:
    """Particles sampled from an image on a grid, one per `step` pixels."""

    def __init__(self, img, step, cx, cy):
        h, w = img.shape[:2]
        ys, xs = np.mgrid[step // 2:h:step, step // 2:w:step]
        self.x0 = xs.ravel().astype(np.float32)
        self.y0 = ys.ravel().astype(np.float32)
        self.col = img[ys.ravel(), xs.ravel()]
        dx, dy = self.x0 - cx, self.y0 - cy
        self.r0 = np.sqrt(dx * dx + dy * dy)
        self.a0 = np.arctan2(dy, dx)
        rng = np.random.default_rng(7)
        self.jitter = rng.uniform(0, 1, self.r0.shape).astype(np.float32)


def splat(frame, x, y, col, size, alpha):
    """Draws particles as size x size squares; later particles overwrite earlier ones."""
    h, w = frame.shape[:2]
    keep = (alpha > 0.02) & (x >= 0) & (y >= 0) & (x < w - size) & (y < h - size)
    xi, yi = x[keep].astype(np.int32), y[keep].astype(np.int32)
    c = col[keep] * alpha[keep][:, None]
    for oy in range(size):
        for ox in range(size):
            frame[yi + oy, xi + ox] = np.maximum(frame[yi + oy, xi + ox], c)


def main(old_path, new_path, out_path, width="3840"):
    W = int(width)
    H = W * 9 // 16
    cx, cy = W / 2, H / 2
    step = max(2, W // 960)  # about 960 x 540 particles
    size = step
    old, new = load(old_path, W, H), load(new_path, W, H)
    fo, fn = Field(old, step, cx, cy), Field(new, step, cx, cy)
    rmax = float(np.sqrt(cx * cx + cy * cy))
    horizon = W * 0.035
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    rr = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    ring = np.exp(-((rr - horizon * 1.04) ** 2) / (2 * (W / 1920) ** 2))[..., None] * 230
    shadow = (rr < horizon)[..., None]
    spin = 2.6  # radians of extra turn gained on the way in

    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
         "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
         out_path],
        stdin=subprocess.PIPE,
    )

    def write(frame):
        ff.stdin.write(frame.clip(0, 255).astype(np.uint8).tobytes())

    def with_hole(frame, strength):
        frame = np.where(shadow, frame * (1 - strength), frame)
        return np.maximum(frame, ring * strength)

    # 1. The sharp old desk; the hole opens at its centre.
    for i in range(round(0.35 * FPS)):
        write(with_hole(old.copy(), smooth((i + 1) / (0.35 * FPS))))

    # 2. Pixels let go (inner ones first) and spiral in.
    n = round(1.5 * FPS)
    for i in range(n):
        T = (i + 1) / n
        start = 0.55 * (fo.r0 / rmax) + 0.08 * fo.jitter
        p = np.clip((T - start) / 0.42, 0, 1)
        e = ease_in(p)
        r = fo.r0 * (1 - e) + horizon * 0.6 * e
        a = fo.a0 + spin * e * e
        alpha = np.where(r < horizon * 1.02, 0.0, 1.0 - 0.35 * e)
        frame = np.zeros((H, W, 3), dtype=np.float32)
        splat(frame, cx + r * np.cos(a), cy + r * np.sin(a), fo.col, size, alpha.astype(np.float32))
        write(with_hole(frame, 1.0))

    # 3. A dark beat: only the ring.
    dark = with_hole(np.zeros((H, W, 3), dtype=np.float32), 1.0)
    for _ in range(round(0.2 * FPS)):
        write(dark)

    # 4. The new desk streams out of the ring and settles.
    n = round(1.45 * FPS)
    for i in range(n):
        T = (i + 1) / n
        start = 0.5 * (fn.r0 / rmax) + 0.08 * fn.jitter
        p = np.clip((T - start) / 0.45, 0, 1)
        e = ease_out(p)
        r = horizon * 1.05 * (1 - e) + fn.r0 * e
        a = fn.a0 - spin * (1 - e) ** 2
        alpha = np.where(p <= 0, 0.0, 0.35 + 0.65 * e)
        frame = np.zeros((H, W, 3), dtype=np.float32)
        splat(frame, cx + r * np.cos(a), cy + r * np.sin(a), fn.col, size, alpha.astype(np.float32))
        write(with_hole(frame, 1.0 - smooth((T - 0.75) / 0.25)))

    # 5. Resolve into the sharp new desk.
    last = np.zeros((H, W, 3), dtype=np.float32)
    splat(last, fn.x0, fn.y0, fn.col, size, np.ones_like(fn.r0))
    for i in range(round(0.4 * FPS)):
        k = smooth((i + 1) / (0.4 * FPS))
        write(last * (1 - k) + new * k)
    for _ in range(round(0.2 * FPS)):
        write(new)
    ff.stdin.close()
    ff.wait()


if __name__ == "__main__":
    main(*sys.argv[1:5])
