# -*- coding: utf-8 -*-
"""diag v1.2.0 host placeholder icon (slice 1).
Generates host/app.ico: rounded dark-blue tile + cyan cross (health check vibe).
Pure Pillow, zero external assets. Slice 2 replaces this with the real icon.
"""
from PIL import Image, ImageDraw

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

TOP = (26, 34, 64)      # deep navy
BOTTOM = (13, 17, 34)   # darker navy
CROSS = (0, 210, 255)   # cyan
S = 256

def build(size):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(S * 0.22)
    # rounded tile with vertical gradient (draw per-line rounded clip)
    for y in range(S):
        t = y / (S - 1)
        col = lerp(TOP, BOTTOM, t)
        d.line([(0, y), (S, y)], fill=col)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([4, 4, S - 5, S - 5], radius=r, fill=255)
    img.putalpha(mask)
    # cyan cross, centered, rounded ends
    d = ImageDraw.Draw(img)
    w = int(S * 0.155)   # bar thickness
    m = int(S * 0.30)    # cross extent margin
    c = S // 2
    d.rounded_rectangle([c - w // 2, m, c + w // 2, S - m], radius=w // 2, fill=CROSS)
    d.rounded_rectangle([m, c - w // 2, S - m, c + w // 2], radius=w // 2, fill=CROSS)
    if size == S:
        return img
    return img.resize((size, size), Image.LANCZOS)

sizes = [256, 48, 32, 16]
base = build(256)
base.save(r"app.ico", format="ICO",
          sizes=[(s, s) for s in sizes], append_images=[build(s) for s in sizes[1:]])
# verify
from PIL import features
chk = Image.open(r"app.ico")
print("ICO written:", chk.format, "base size:", chk.size, "layers:", getattr(chk, "ico", None) is not None)
