# -*- coding: utf-8 -*-
"""diag v1.2.0 slice 2 icon generator (assets/icon-src/gen_icons.py).

Pure Pillow, zero external assets (zero-copyright rule, 1023).
4 style directions x 3 drafts = 12 candidates:
  A gradient geometric badge   (A1 pulse / A2 shield-check / A3 hex-cross)
  B linear minimal shield      (B1 neon outline / B2 shield silhouette / B3 nested outline)
  C dark glass glow            (C1 glow progress ring / C2 glass panel + ECG / C3 radar pulse)
  D circuit pulse              (D1 circuit ECG / D2 chip checkup / D3 gear pulse)

Each draft -> drafts/<ID>.png (512) + drafts/<ID>.ico (16/32/48/256).
Also builds sheet_round1.png (candidate contact sheet with real-size 16px pixels).
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DRAFTS = os.path.join(HERE, "drafts")
SS = 2048          # supersample canvas
BASE = 512         # master size

os.makedirs(DRAFTS, exist_ok=True)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def grad(size, c1, c2, dx=1.0, dy=1.0):
    """Linear gradient via 256px computation + smooth upscale."""
    n = 256
    small = Image.new("RGB", (n, n))
    p = small.load()
    denom = abs(dx) + abs(dy)
    for y in range(n):
        for x in range(n):
            t = ((x / (n - 1)) * dx + (y / (n - 1)) * dy) / denom
            t = 0.0 if t < 0 else (1.0 if t > 1 else t)
            p[x, y] = lerp(c1, c2, t)
    return small.resize((size, size), Image.BILINEAR).convert("RGBA")


def flat(size, c):
    return Image.new("RGBA", (size, size), c + (255,))


def round_tile(img, radius=0.22, inset=0.0):
    """Clip a gradient/flat image into a rounded-square tile."""
    s = img.size[0]
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    m = int(s * inset)
    d.rounded_rectangle([m, m, s - 1 - m, s - 1 - m], radius=int(s * radius), fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def circle_tile(img, inset=0.0):
    s = img.size[0]
    mask = Image.new("L", (s, s), 0)
    m = int(s * inset)
    ImageDraw.Draw(mask).ellipse([m, m, s - 1 - m, s - 1 - m], fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def line_r(d, pts, w, fill):
    """Polyline with round joints and round end caps."""
    d.line(pts, fill=fill, width=w, joint="curve")
    r = w // 2
    for (x, y) in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def bez(p0, p1, p2, p3, n=32):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def shield_pts(cx, cy, w, h):
    """Classic shield: gently curved top, sides tapering to bottom point."""
    lt, rt = (cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2)
    top = bez((lt[0], lt[1] + h * 0.10), (cx - w * 0.22, cy - h / 2 - h * 0.06),
              (cx + w * 0.22, cy - h / 2 - h * 0.06), (rt[0], rt[1] + h * 0.10))
    right = bez((rt[0], rt[1] + h * 0.10), (rt[0], cy + h * 0.18),
                (cx + w * 0.34, cy + h * 0.34), (cx, cy + h / 2))
    left = [(2 * cx - x, y) for (x, y) in right[::-1]]
    return top + right + left[:-1] + left


def check(d, cx, cy, size, w, fill):
    line_r(d, [(cx - size * 0.46, cy + size * 0.02),
               (cx - size * 0.10, cy + size * 0.36),
               (cx + size * 0.50, cy - size * 0.30)], w, fill)


def pulse(d, cx, cy, length, amp, lw, fill):
    x0 = cx - length / 2
    pts = [(x0, cy), (x0 + length * 0.26, cy), (x0 + length * 0.40, cy - amp * 0.55),
           (x0 + length * 0.54, cy + amp * 0.50), (x0 + length * 0.66, cy),
           (cx + length / 2, cy)]
    line_r(d, pts, lw, fill)


def cross(d, cx, cy, arm, lw, fill):
    d.rounded_rectangle([cx - lw / 2, cy - arm, cx + lw / 2, cy + arm], radius=lw // 2, fill=fill)
    d.rounded_rectangle([cx - arm, cy - lw / 2, cx + arm, cy + lw / 2], radius=lw // 2, fill=fill)


def hex_pts(cx, cy, r, pointy=True):
    pts = []
    for i in range(6):
        a = (i * 60 + (30 if pointy else 0)) * 3.1415926 / 180
        pts.append((cx + r * __import__("math").cos(a), cy + r * __import__("math").sin(a)))
    return pts


def glow(base, painter, blur):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    painter(ImageDraw.Draw(layer))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(layer)


def finish(img, name):
    """Downscale to 512 master, save png + ico(16/32/48/256)."""
    master = img.resize((BASE, BASE), Image.LANCZOS)
    master.save(os.path.join(DRAFTS, name + ".png"), format="PNG")
    # ICO 容器上限 256px：基图必须恰好 256，否则 (256,256) 槽位匹配不到提供图（Pillow
    # thumbnail 分支缩图不放大，实测 256 层静默丢失）——256 基图 + 48/32/16 逐层提供。
    sizes = [256, 48, 32, 16]
    layers = [master.resize((s, s), Image.LANCZOS) for s in sizes]
    layers[0].save(os.path.join(DRAFTS, name + ".ico"), format="ICO",
                   sizes=[(s, s) for s in sizes], append_images=layers[1:])


# ---------------- Direction A: gradient geometric badge ----------------

def A1():
    s = SS
    img = round_tile(grad(s, (28, 40, 80), (0, 150, 225), 1, 1))
    d = ImageDraw.Draw(img)
    glow(img, lambda g: pulse(g, s / 2, s / 2, s * 0.58, s * 0.20, int(s * 0.065), (0, 210, 255, 160)), s * 0.03)
    pulse(d, s / 2, s / 2, s * 0.58, s * 0.20, int(s * 0.065), (255, 255, 255, 255))
    return img


def A2():
    s = SS
    img = round_tile(grad(s, (40, 70, 215), (120, 62, 220), 1, 1))
    d = ImageDraw.Draw(img)
    pts = shield_pts(s / 2, s / 2, s * 0.52, s * 0.56)
    d.polygon(pts, fill=(255, 255, 255, 255))
    check(d, s / 2, s / 2 - s * 0.01, s * 0.22, int(s * 0.055), (45, 35, 130, 255))
    return img


def A3():
    s = SS
    img = round_tile(grad(s, (0, 135, 125), (0, 215, 160), 1, 1))
    d = ImageDraw.Draw(img)
    d.line(hex_pts(s / 2, s / 2, s * 0.335) + [hex_pts(s / 2, s / 2, s * 0.335)[0]],
           fill=(255, 255, 255, 110), width=int(s * 0.038), joint="curve")
    cross(d, s / 2, s / 2, s * 0.155, int(s * 0.115), (255, 255, 255, 255))
    return img


# ---------------- Direction B: linear minimal shield ----------------

def B1():
    s = SS
    img = round_tile(grad(s, (10, 16, 34), (14, 24, 52), 1, 1))
    d = ImageDraw.Draw(img)
    pts = shield_pts(s / 2, s / 2, s * 0.50, s * 0.55)
    glow(img, lambda g: g.line(pts + [pts[0]], fill=(0, 220, 255, 170), width=int(s * 0.05), joint="curve"), s * 0.035)
    d.line(pts + [pts[0]], fill=(0, 225, 255, 255), width=int(s * 0.05), joint="curve")
    check(d, s / 2, s / 2 - s * 0.005, s * 0.20, int(s * 0.048), (0, 225, 255, 255))
    return img


def B2():
    s = SS
    gradf = grad(s, (20, 44, 110), (0, 130, 190), 1, 1)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).polygon(shield_pts(s / 2, s / 2 + s * 0.02, s * 0.74, s * 0.80), fill=255)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    img.paste(gradf, (0, 0), mask)
    d = ImageDraw.Draw(img)
    pts = shield_pts(s / 2, s / 2 + s * 0.02, s * 0.62, s * 0.67)
    d.line(pts + [pts[0]], fill=(120, 230, 255, 220), width=int(s * 0.028), joint="curve")
    check(d, s / 2, s / 2 + s * 0.005, s * 0.26, int(s * 0.06), (255, 255, 255, 255))
    return img


def B3():
    s = SS
    img = round_tile(grad(s, (12, 18, 40), (8, 12, 28), 1, 1))
    d = ImageDraw.Draw(img)
    outer = shield_pts(s / 2, s / 2, s * 0.56, s * 0.62)
    inner = shield_pts(s / 2, s / 2, s * 0.38, s * 0.42)
    d.line(outer + [outer[0]], fill=(90, 200, 255, 120), width=int(s * 0.026), joint="curve")
    d.line(inner + [inner[0]], fill=(230, 245, 255, 255), width=int(s * 0.042), joint="curve")
    r = int(s * 0.045)
    d.ellipse([s / 2 - r, s / 2 + s * 0.03 - r, s / 2 + r, s / 2 + s * 0.03 + r], fill=(0, 225, 255, 255))
    return img


# ---------------- Direction C: dark glass glow ----------------

def C1():
    s = SS
    img = round_tile(grad(s, (8, 12, 26), (14, 20, 44), 1, 1))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    r = s * 0.30
    lw = int(s * 0.072)
    # glass highlight (upper half soft sheen)
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).pieslice([s * 0.06, s * 0.02, s * 0.94, s * 0.72], 180, 360,
                                   fill=(255, 255, 255, 26))
    img.alpha_composite(sheen.filter(ImageFilter.GaussianBlur(s * 0.02)))
    # track ring + glowing progress arc
    d.arc([cx - r, cy - r, cx + r, cy + r], 0, 360, fill=(46, 58, 84, 255), width=lw)
    glow(img, lambda g: g.arc([cx - r, cy - r, cx + r, cy + r], -90, 180,
                              fill=(0, 210, 255, 220), width=lw), s * 0.03)
    d.arc([cx - r, cy - r, cx + r, cy + r], -90, 180, fill=(0, 225, 255, 255), width=lw)
    er = lw // 2
    d.ellipse([cx - er, cy - r - er, cx + er, cy - r + er], fill=(180, 250, 255, 255))
    check(d, cx, cy + s * 0.005, s * 0.16, int(s * 0.042), (240, 250, 255, 255))
    return img


def C2():
    s = SS
    img = round_tile(grad(s, (30, 18, 62), (10, 14, 38), 1, 1))
    d = ImageDraw.Draw(img)
    pane = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(pane).polygon([(s * 0.10, s * 0.10), (s * 0.90, s * 0.10),
                                  (s * 0.10, s * 0.90)], fill=(255, 255, 255, 30))
    img.alpha_composite(pane.filter(ImageFilter.GaussianBlur(s * 0.008)))
    d.line([(s * 0.90, s * 0.10), (s * 0.90, s * 0.90), (s * 0.10, s * 0.90)],
           fill=(255, 255, 255, 60), width=int(s * 0.012), joint="curve")
    glow(img, lambda g: pulse(g, s / 2, s / 2, s * 0.60, s * 0.22, int(s * 0.055), (255, 60, 200, 150)), s * 0.03)
    pulse(d, s / 2, s / 2, s * 0.60, s * 0.22, int(s * 0.055), (60, 235, 255, 255))
    return img


def C3():
    s = SS
    img = circle_tile(grad(s, (6, 10, 24), (12, 18, 40), 1, 1))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    for rr, a in ((s * 0.40, 70), (s * 0.27, 110)):
        d.arc([cx - rr, cy - rr, cx + rr, cy + rr], 0, 360, fill=(0, 200, 255, a), width=int(s * 0.018))
    glow(img, lambda g: g.ellipse([cx - s * 0.09, cy - s * 0.09, cx + s * 0.09, cy + s * 0.09],
                                  fill=(0, 220, 255, 220)), s * 0.05)
    r = s * 0.055
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(200, 250, 255, 255))
    d.pieslice([cx - s * 0.40, cy - s * 0.40, cx + s * 0.40, cy + s * 0.40], -64, -8,
               fill=(0, 210, 255, 60))
    return img


# ---------------- Direction D: circuit pulse ----------------

def D1():
    s = SS
    img = round_tile(grad(s, (10, 18, 38), (6, 12, 26), 1, 1))
    d = ImageDraw.Draw(img)
    lw = int(s * 0.022)
    tr = (0, 190, 255, 150)
    m, cx = s * 0.14, s / 2
    for p in ([(m, m), (m, s * 0.32), (s * 0.34, s * 0.32)],
              [(s - m, m), (s - m, s * 0.32), (s * 0.66, s * 0.32)],
              [(m, s - m), (m, s * 0.68), (s * 0.34, s * 0.68)],
              [(s - m, s - m), (s - m, s * 0.68), (s * 0.66, s * 0.68)]):
        line_r(d, p, lw, tr)
        r = int(s * 0.020)
        d.ellipse([p[0][0] - r, p[0][1] - r, p[0][0] + r, p[0][1] + r], fill=tr)
    glow(img, lambda g: pulse(g, cx, cx, s * 0.46, s * 0.16, int(s * 0.055), (0, 210, 255, 160)), s * 0.03)
    pulse(d, cx, cx, s * 0.46, s * 0.16, int(s * 0.055), (240, 252, 255, 255))
    return img


def D2():
    s = SS
    img = round_tile(grad(s, (6, 26, 22), (4, 42, 36), 1, 1))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    chip = s * 0.40
    d.rounded_rectangle([cx - chip / 2, cy - chip / 2, cx + chip / 2, cy + chip / 2],
                        radius=int(s * 0.05), outline=(140, 255, 220, 230), width=int(s * 0.020))
    pin, plen = s * 0.030, s * 0.075
    for i in (-1, 0, 1):
        off = i * s * 0.105
        for (x0, y0, x1, y1) in ((cx + off, cy - chip / 2 - plen, cx + off, cy - chip / 2),
                                 (cx + off, cy + chip / 2, cx + off, cy + chip / 2 + plen),
                                 (cx - chip / 2 - plen, cy + off, cx - chip / 2, cy + off),
                                 (cx + chip / 2, cy + off, cx + chip / 2 + plen, cy + off)):
            d.rounded_rectangle([min(x0, x1) - pin / 2, min(y0, y1) - pin / 2,
                                 max(x0, x1) + pin / 2, max(y0, y1) + pin / 2],
                                radius=pin // 2, fill=(90, 230, 200, 190))
    cross(d, cx, cy, s * 0.105, int(s * 0.078), (235, 255, 250, 255))
    return img


def D3():
    s = SS
    img = round_tile(grad(s, (14, 18, 30), (8, 10, 20), 1, 1))
    d = ImageDraw.Draw(img)
    cx = cy = s / 2
    ro, ri, teeth = s * 0.36, s * 0.265, 9
    import math
    pts = []
    step = 360.0 / teeth
    for i in range(teeth):
        a0, a1, a2, a3 = (i * step - step * 0.30, i * step - step * 0.12,
                          i * step + step * 0.12, i * step + step * 0.30)
        for a, r in ((a0, ri), (a1, ro), (a2, ro), (a3, ri)):
            rad = a * math.pi / 180
            pts.append((cx + r * math.cos(rad), cy + r * math.sin(rad)))
    d.polygon(pts, fill=(255, 176, 46, 235))
    hole = s * 0.205
    d.ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=(12, 15, 26, 255))
    glow(img, lambda g: pulse(g, cx, cy, s * 0.30, s * 0.095, int(s * 0.045), (0, 210, 255, 150)), s * 0.025)
    pulse(d, cx, cy, s * 0.30, s * 0.095, int(s * 0.045), (240, 250, 255, 255))
    return img


# ---------------- contact sheet ----------------

def font(sz):
    for name in ("arial.ttf", "segoeui.ttf"):
        try:
            return ImageFont.truetype("C:/Windows/Fonts/" + name, sz)
        except Exception:
            continue
    return ImageFont.load_default()


def build_sheet(ids, path):
    cell_w, head, prev, small_gap, label_h = 320, 64, 256, 8, 46
    rows = (len(ids) + 2) // 3
    sheet = Image.new("RGB", (cell_w * 3 + 40, head + rows * (prev + label_h + 96) + 20), (22, 26, 36))
    d = ImageDraw.Draw(sheet)
    f_big, f_lab = font(30), font(28)
    for idx, did in enumerate(ids):
        col, row = idx % 3, idx // 3
        x0 = 20 + col * cell_w
        y0 = head + row * (prev + label_h + 96)
        d.text((x0, y0 + 6), did, font=f_big, fill=(120, 220, 255))
        img = Image.open(os.path.join(DRAFTS, did + ".png")).convert("RGBA")
        sheet.paste(img.resize((prev, prev), Image.LANCZOS), (x0, y0 + label_h), img.resize((prev, prev), Image.LANCZOS))
        y1 = y0 + label_h + prev + 10
        xx = x0
        for sz in (48, 32):
            im = img.resize((sz, sz), Image.LANCZOS)
            sheet.paste(im, (xx, y1), im)
            xx += sz + small_gap
        im16 = img.resize((16, 16), Image.LANCZOS)
        sheet.paste(im16, (xx, y1 + 16), im16)
        im16x = im16.resize((64, 64), Image.NEAREST)
        sheet.paste(im16x, (xx + 34, y1), im16x)
        d.text((xx + 108, y1 + 18), "48/32/16 px", font=f_lab, fill=(200, 205, 215))
    sheet.save(path, format="PNG")
    return sheet.size


def selfcheck():
    from PIL import IcoImagePlugin
    ids = [d + str(i) for d, n in (("A", 3), ("B", 3), ("C", 3), ("D", 3)) for i in range(1, n + 1)]
    ok = True
    for did in ids:
        png = os.path.join(DRAFTS, did + ".png")
        ico = os.path.join(DRAFTS, did + ".ico")
        im = Image.open(png)
        with open(ico, "rb") as fh:
            layers = sorted(IcoImagePlugin.IcoFile(fh).sizes())
        good = (im.format == "PNG" and im.size == (512, 512)
                and layers == [(16, 16), (32, 32), (48, 48), (256, 256)]
                and os.path.getsize(ico) > 4000)
        ok = ok and good
        print(("OK  " if good else "BAD ") + did, "png512", layers, os.path.getsize(ico), "bytes")
    print("SELFCHECK:", "PASS" if ok else "FAIL")


if __name__ == "__main__":
    builders = {"A1": A1, "A2": A2, "A3": A3, "B1": B1, "B2": B2, "B3": B3,
                "C1": C1, "C2": C2, "C3": C3, "D1": D1, "D2": D2, "D3": D3}
    for k, fn in builders.items():
        finish(fn(), k)
        print("built", k)
    print("sheet:", build_sheet(list(builders.keys()), os.path.join(HERE, "sheet_round1.png")))
    selfcheck()
