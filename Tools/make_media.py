r"""Generate anti-aliased RGBA PNG UI assets for ReadyToWork\Media\.

Uses 4x4 supersampled signed-distance-field (SDF) rasterization with pure
Python standard library (math, os, struct, zlib).
"""

import math
import os
import struct
import zlib


OUT_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Media")
)


def write_png(path, width, height, rgba_rows):
    """Write an 8-bit RGBA PNG file from rows of (r, g, b, a) byte tuples."""
    raw = bytearray()
    for row in rgba_rows:
        raw.append(0)  # filter type 0 (None)
        for r, g, b, a in row:
            raw.extend((r, g, b, a))

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else (hi if v > hi else v)


def smooth_cov(sdf, aa=0.85):
    """Convert signed distance (<=0 inside) to coverage [0..1]."""
    return clamp(0.5 - sdf / aa)


def supersample(width, height, fn, samples=4):
    """Evaluate fn(x, y) -> (r, g, b, a) floats 0..1 on a 4x4 subpixel grid."""
    rows = []
    inv = 1.0 / samples
    norm = 1.0 / (samples * samples)
    offsets = [(i + 0.5) * inv for i in range(samples)]
    for py in range(height):
        row = []
        for px in range(width):
            sr = sg = sb = sa = 0.0
            for oy in offsets:
                y = py + oy
                for ox in offsets:
                    x = px + ox
                    r, g, b, a = fn(x, y)
                    sr += r * a
                    sg += g * a
                    sb += b * a
                    sa += a
            a_avg = sa * norm
            if a_avg > 1e-6:
                r_out = int(round(clamp(sr / sa) * 255))
                g_out = int(round(clamp(sg / sa) * 255))
                b_out = int(round(clamp(sb / sa) * 255))
            else:
                r_out = g_out = b_out = 0
            a_out = int(round(clamp(a_avg) * 255))
            row.append((r_out, g_out, b_out, a_out))
        rows.append(row)
    return rows


def sd_round_box(px, py, cx, cy, hw, hh, r):
    """Signed distance to an axis-aligned rounded box centered at (cx, cy)."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    dx = max(qx, 0.0)
    dy = max(qy, 0.0)
    return math.hypot(dx, dy) + min(max(qx, qy), 0.0) - r


def sd_segment(px, py, ax, ay, bx, by):
    """Unsigned distance from (px, py) to segment (ax, ay)-(bx, by)."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    denom = vx * vx + vy * vy
    t = clamp((wx * vx + wy * vy) / denom) if denom > 0 else 0.0
    dx = wx - vx * t
    dy = wy - vy * t
    return math.hypot(dx, dy)


def make_round_fill(w, h, radius, inset=0.5):
    cx, cy = w * 0.5, h * 0.5
    hw, hh = w * 0.5 - inset, h * 0.5 - inset

    def fn(x, y):
        d = sd_round_box(x, y, cx, cy, hw, hh, radius)
        return (1.0, 1.0, 1.0, smooth_cov(d))

    return supersample(w, h, fn)


def make_round_border(w, h, radius, thickness, inset=0.5):
    cx, cy = w * 0.5, h * 0.5
    hw, hh = w * 0.5 - inset, h * 0.5 - inset

    def fn(x, y):
        d_outer = sd_round_box(x, y, cx, cy, hw, hh, radius)
        # Inside-aligned hairline border: region between d_outer <= 0 and d_outer >= -thickness
        cov_outer = smooth_cov(d_outer)
        cov_inner = smooth_cov(d_outer + thickness)
        a = clamp(cov_outer - cov_inner)
        return (1.0, 1.0, 1.0, a)

    return supersample(w, h, fn)


def make_circle(size, radius):
    cx = cy = size * 0.5

    def fn(x, y):
        d = math.hypot(x - cx, y - cy) - radius
        return (1.0, 1.0, 1.0, smooth_cov(d))

    return supersample(size, size, fn)


def make_circle_ring(size, outer_radius, thickness):
    cx = cy = size * 0.5

    def fn(x, y):
        d_out = math.hypot(x - cx, y - cy) - outer_radius
        cov_out = smooth_cov(d_out)
        cov_in = smooth_cov(d_out + thickness)
        return (1.0, 1.0, 1.0, clamp(cov_out - cov_in))

    return supersample(size, size, fn)


def make_glow(size):
    cx = cy = size * 0.5
    max_r = size * 0.5

    def fn(x, y):
        r = math.hypot(x - cx, y - cy) / max_r
        if r >= 1.0:
            return (1.0, 1.0, 1.0, 0.0)
        # Smooth Gaussian glow with clean fade to 0 at r = 1
        edge_fade = clamp(1.0 - r * r)
        a = math.exp(-4.5 * r * r) * edge_fade
        return (1.0, 1.0, 1.0, clamp(a))

    return supersample(size, size, fn, samples=2)


def make_shadow(size=64, margin=16):
    """64x64 black shadow with transparent center (16..48) and soft outer falloff."""
    cx = cy = size * 0.5
    inner_half = cx - margin  # 16

    def fn(x, y):
        # Distance outside the inner box (16..48)
        dx = max(abs(x - cx) - inner_half, 0.0)
        dy = max(abs(y - cy) - inner_half, 0.0)
        dist = math.hypot(dx, dy)
        if dist <= 0.0:
            return (0.0, 0.0, 0.0, 0.0)
        if dist >= margin:
            return (0.0, 0.0, 0.0, 0.0)
        t = dist / margin
        # Smooth bell/Gaussian falloff fading cleanly to 0 at margin
        a = math.exp(-4.2 * t * t) * (1.0 - t)
        return (0.0, 0.0, 0.0, clamp(a))

    return supersample(size, size, fn, samples=2)


def make_icon_search(size=32):
    stroke_r = 2.1 * 0.5

    def fn(x, y):
        d_ring = abs(math.hypot(x - 13.5, y - 13.5) - 6.5) - stroke_r
        d_handle = sd_segment(x, y, 18.2, 18.2, 25.5, 25.5) - stroke_r
        d = min(d_ring, d_handle)
        return (1.0, 1.0, 1.0, smooth_cov(d))

    return supersample(size, size, fn)


def make_icon_close(size=32):
    stroke_r = 2.1 * 0.5

    def fn(x, y):
        d1 = sd_segment(x, y, 9.0, 9.0, 23.0, 23.0) - stroke_r
        d2 = sd_segment(x, y, 23.0, 9.0, 9.0, 23.0) - stroke_r
        return (1.0, 1.0, 1.0, smooth_cov(min(d1, d2)))

    return supersample(size, size, fn)


def make_icon_more(size=32):
    centers = (8.5, 16.0, 23.5)

    def fn(x, y):
        d = min(math.hypot(x - cx, y - 16.0) - 2.2 for cx in centers)
        return (1.0, 1.0, 1.0, smooth_cov(d))

    return supersample(size, size, fn)


def make_icon_check(size=32):
    stroke_r = 2.5 * 0.5

    def fn(x, y):
        d1 = sd_segment(x, y, 7.5, 16.5, 13.2, 22.0) - stroke_r
        d2 = sd_segment(x, y, 13.2, 22.0, 24.5, 10.5) - stroke_r
        return (1.0, 1.0, 1.0, smooth_cov(min(d1, d2)))

    return supersample(size, size, fn)


def make_icon_grip(size=32):
    pts = ((24, 24), (18, 24), (24, 18), (12, 24), (18, 18), (24, 12))

    def fn(x, y):
        d = min(math.hypot(x - px, y - py) - 1.5 for px, py in pts)
        return (1.0, 1.0, 1.0, smooth_cov(d))

    return supersample(size, size, fn)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    specs = [
        ("panel_fill.png", 64, 64, lambda: make_round_fill(64, 64, 12.0, inset=0.5)),
        ("panel_border.png", 64, 64, lambda: make_round_border(64, 64, 12.0, 1.25, inset=0.5)),
        ("card_fill.png", 48, 48, lambda: make_round_fill(48, 48, 8.0, inset=0.5)),
        ("card_border.png", 48, 48, lambda: make_round_border(48, 48, 8.0, 1.15, inset=0.5)),
        ("pill_fill.png", 48, 24, lambda: make_round_fill(48, 24, 11.0, inset=0.5)),
        ("pill_border.png", 48, 24, lambda: make_round_border(48, 24, 11.0, 1.15, inset=0.5)),
        ("circle.png", 32, 32, lambda: make_circle(32, 13.5)),
        ("circle_ring.png", 32, 32, lambda: make_circle_ring(32, 13.5, 2.2)),
        ("glow.png", 48, 48, lambda: make_glow(48)),
        ("shadow.png", 64, 64, lambda: make_shadow(64, 16)),
        ("mask_icon.png", 64, 64, lambda: make_round_fill(64, 64, 13.0, inset=1.0)),
        ("icon_search.png", 32, 32, lambda: make_icon_search(32)),
        ("icon_close.png", 32, 32, lambda: make_icon_close(32)),
        ("icon_more.png", 32, 32, lambda: make_icon_more(32)),
        ("icon_check.png", 32, 32, lambda: make_icon_check(32)),
        ("icon_grip.png", 32, 32, lambda: make_icon_grip(32)),
    ]
    for name, w, h, builder in specs:
        out_path = os.path.join(OUT_DIR, name)
        rows = builder()
        write_png(out_path, w, h, rows)
        print(f"Generated {name} ({w}x{h})")


if __name__ == "__main__":
    main()
