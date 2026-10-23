# -*- coding: utf-8 -*-
"""diag v1.2.0 slice 2: install user-picked draft B1 into the three swap points.

B1 = neon shield outline + check on dark tile (user picked 1023, guicheck round-1 TOP1).
Swaps: host/app.ico (exe+window icon, Inno SetupIconFile follows), ui/brand.png,
ui/favicon.png, and diag-lite/ui mirrors (packaged copies).
"""
import os
import shutil
from PIL import Image, IcoImagePlugin

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # diag/
SRC = os.path.join(HERE, "drafts", "B1")
PAD = 0.04                                               # brand-mark 内衬，防 CSS 圆角裁到贴片圆角

# 1) host/app.ico
shutil.copyfile(SRC + ".ico", os.path.join(ROOT, "host", "app.ico"))

# 2) brand.png：512 主稿 → 256 正方形 + 4% 透明内衬
master = Image.open(SRC + ".png").convert("RGBA")
side = 256
pad = int(side * PAD)
inner = side - 2 * pad
brand = Image.new("RGBA", (side, side), (0, 0, 0, 0))
brand.paste(master.resize((inner, inner), Image.LANCZOS), (pad, pad), master.resize((inner, inner), Image.LANCZOS))
# 3) favicon.png：32px
fav = master.resize((32, 32), Image.LANCZOS)
for sub in ("ui", os.path.join("diag-lite", "ui")):
    brand.save(os.path.join(ROOT, sub, "brand.png"), format="PNG")
    fav.save(os.path.join(ROOT, sub, "favicon.png"), format="PNG")

# 回读断言（R4③：不信写盘自印，重开读档核实）
for sub in ("ui", os.path.join("diag-lite", "ui")):
    b = Image.open(os.path.join(ROOT, sub, "brand.png"))
    f = Image.open(os.path.join(ROOT, sub, "favicon.png"))
    assert b.format == "PNG" and b.size == (256, 256), (sub, b.format, b.size)
    assert f.format == "PNG" and f.size == (32, 32), (sub, f.format, f.size)
with open(os.path.join(ROOT, "host", "app.ico"), "rb") as fh:
    layers = sorted(IcoImagePlugin.IcoFile(fh).sizes())
assert layers == [(16, 16), (32, 32), (48, 48), (256, 256)], layers
# 三份 ico 一致性：host 与源稿逐字节同
assert open(os.path.join(ROOT, "host", "app.ico"), "rb").read() == open(SRC + ".ico", "rb").read()
print("SWAP OK: host/app.ico 4-layer; brand 256x256; favicon 32x32 (ui + diag-lite/ui)")
