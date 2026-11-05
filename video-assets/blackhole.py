"""Black-hole crossing between two real desk screenshots, rendered frame by frame.

Point-mass gravitational lens (thin-lens equation): an image-plane point at radius r from the hole shows the
source point at radius beta = r - thetaE^2 / r along the same angle (a negative beta flips to the opposite side,
which draws the inner image). Inside the shadow the frame is black. A hairline photon ring marks its edge.

Phase A: the old desk is pulled in; the shadow grows until the screen is black.
Phase B: a short dark beat.
Phase C: the other side; the shadow shrinks and the new desk settles, sharp.

Usage: python3 blackhole.py <old.png> <new.png> <out.mp4>
"""
import subprocess
import sys

import numpy as np
from PIL import Image

W, H, FPS = 1920, 1080, 60
A_SEC, B_SEC, C_SEC = 1.35, 0.22, 1.55
RING = np.array([236, 238, 242], dtype=np.float32)  # neutral white, a hairline


def load_cover(path):
    """Scale to cover 1920x1080, keep the top of the screenshot (the content), crop the rest."""
    im = Image.open(path).convert("RGB")
    scale = max(W / im.width, H / im.height)
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    left = (im.width - W) // 2
    return np.asarray(im.crop((left, 0, left + W, H)), dtype=np.float32)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def ease_in(t):
    return t ** 3


def ease_out(t):
    return 1 - (1 - t) ** 3


yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
cx, cy = W / 2, H / 2
dx, dy = xx - cx, yy - cy
r = np.sqrt(dx * dx + dy * dy) + 1e-3
ang = np.arctan2(dy, dx)
HALF_DIAG = float(np.sqrt(cx * cx + cy * cy))


def sample(src, sx, sy):
    """Bilinear sample with edge clamp."""
    sx = np.clip(sx, 0, W - 1.001)
    sy = np.clip(sy, 0, H - 1.001)
    x0 = sx.astype(np.int32)
    y0 = sy.astype(np.int32)
    fx = (sx - x0)[..., None]
    fy = (sy - y0)[..., None]
    a = src[y0, x0]
    b = src[y0, x0 + 1]
    c = src[y0 + 1, x0]
    d = src[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def lensed(src, theta_e, shadow, twist):
    """One frame: src seen past a hole with Einstein radius theta_e and shadow radius shadow."""
    if theta_e < 0.5:
        return src.copy()
    beta = r - theta_e * theta_e / r
    a = ang + twist * (theta_e * theta_e) / (r * r + theta_e * theta_e)  # gentle frame dragging near the hole
    flip = beta < 0
    beta_abs = np.abs(beta)
    a = np.where(flip, a + np.pi, a)
    sx = cx + beta_abs * np.cos(a)
    sy = cy + beta_abs * np.sin(a)
    out = sample(src, sx, sy)
    # The shadow: black inside, anti-aliased edge.
    inside = 1.0 - smoothstep(shadow - 1.2, shadow + 1.2, r)
    out = out * (1.0 - inside[..., None])
    # Hairline photon ring just outside the shadow.
    ring = np.exp(-((r - shadow * 1.035) ** 2) / (2 * 1.1 ** 2)) * 0.85
    out = out * (1 - ring[..., None]) + RING * ring[..., None]
    return out


def main(old_path, new_path, out_path):
    old, new = load_cover(old_path), load_cover(new_path)
    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
         "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
         out_path],
        stdin=subprocess.PIPE,
    )
    max_shadow = HALF_DIAG * 1.06
    n_a, n_b, n_c = round(A_SEC * FPS), round(B_SEC * FPS), round(C_SEC * FPS)
    for i in range(n_a):  # pulled in
        t = ease_in((i + 1) / n_a)
        shadow = max_shadow * t
        theta_e = shadow / 0.55 * (0.35 + 0.65 * t)
        ff.stdin.write(lensed(old, theta_e, shadow, twist=0.9 * t).clip(0, 255).astype(np.uint8).tobytes())
    black = np.zeros((H, W, 3), dtype=np.uint8).tobytes()
    for _ in range(n_b):  # the crossing
        ff.stdin.write(black)
    for i in range(n_c):  # the other side
        t = ease_out((i + 1) / n_c)
        shadow = max_shadow * (1 - t)
        theta_e = shadow / 0.55 * (0.35 + 0.65 * (1 - t))
        ff.stdin.write(lensed(new, theta_e, shadow, twist=-0.9 * (1 - t)).clip(0, 255).astype(np.uint8).tobytes())
    for _ in range(round(0.25 * FPS)):  # settle on the sharp desk
        ff.stdin.write(new.clip(0, 255).astype(np.uint8).tobytes())
    ff.stdin.close()
    ff.wait()


if __name__ == "__main__":
    main(*sys.argv[1:4])
