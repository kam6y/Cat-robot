"""あくびの参考画像（または描画した 1280×720 のキャンバス）の実測。画像全体が 16:9 のキャンバス。
色の分類ごとの連結成分を取り、外接（キャンバス正規化座標 cv）と列・行ごとの縁を出す。PIL と numpy が要る。
usage: /usr/bin/python3 measure_yawn.py IMAGE [CROP_DIR]
  CROP_DIR を渡すと、目と口の拡大切り抜きを書く（目視用）。"""
import os, sys
from collections import deque
import numpy as np
from PIL import Image

path = sys.argv[1]
crop_dir = sys.argv[2] if len(sys.argv) > 2 else None
im = Image.open(path).convert("RGB")
W, H = im.size
a = np.asarray(im).astype(int)
print(f"== {os.path.basename(path)} {W}x{H} ({W / H:.4f}:1)")

# 代表色（製品の Palette と、参考画像の実測で寄せた値）。最も近い色に分類し、どれからも遠い画素は other。
PROTOS = {
    "black": (6, 5, 5), "gold": (247, 196, 62), "cream": (249, 233, 203), "coral": (250, 135, 110),
    "maroon": (58, 26, 30), "pink": (240, 135, 135), "white": (252, 251, 249),
}
names = list(PROTOS)
protos = np.array([PROTOS[n] for n in names])
d = ((a[..., None, :] - protos[None, None, :, :]) ** 2).sum(-1)
cls = d.argmin(-1)
cls[d.min(-1) > 60 ** 2] = -1
for i, n in enumerate(names):
    m = cls == i
    if m.sum() and n != "black":
        mean = a[m].mean(0)
        print(f"class {n:6s} px {m.sum():7d} mean #{int(mean[0]):02X}{int(mean[1]):02X}{int(mean[2]):02X}")
print(f"class other  px {(cls == -1).sum():7d}")


def comps(mask, minimum=30):
    seen = np.zeros_like(mask, bool)
    out = []
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if seen[y0, x0]:
            continue
        q = deque([(y0, x0)]); seen[y0, x0] = True; pts = []
        while q:
            y, x = q.popleft(); pts.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < H and 0 <= xx < W and mask[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True; q.append((yy, xx))
        if len(pts) >= minimum:
            out.append(np.array(pts))
    out.sort(key=lambda p: -len(p))
    return out


def bbox(p):
    return (p[:, 1].min(), p[:, 1].max() + 1, p[:, 0].min(), p[:, 0].max() + 1)


def describe(label, p):
    x0, x1, y0, y1 = bbox(p)
    print(f"{label}: px x {x0}..{x1} y {y0}..{y1} | cv x {x0 / W:.4f}..{x1 / W:.4f} y {y0 / H:.4f}..{y1 / H:.4f}"
          f" c ({(x0 + x1) / 2 / W:.4f}, {(y0 + y1) / 2 / H:.4f}) size ({(x1 - x0) / W:.4f}, {(y1 - y0) / H:.4f}) n {len(p)}")


def columns(p, samples=21):
    """等間隔の列で (cv x, 上縁 cv y, 下縁 cv y, 太さ cv) を出す。"""
    x0, x1, _, _ = bbox(p)
    col = {}
    for y, x in p:
        t = col.get(x)
        col[x] = (y, y) if t is None else (min(t[0], y), max(t[1], y))
    xs = sorted(col)
    rows = []
    for i in range(samples):
        x = x0 + int((x1 - 1 - x0) * i / (samples - 1))
        x = min(xs, key=lambda v: abs(v - x))
        top, bottom = col[x]
        rows.append(f"({x / W:.4f}: {top / H:.4f}..{(bottom + 1) / H:.4f} t{(bottom + 1 - top) / H:.4f})")
    return " ".join(rows)


def rows_profile(p, samples=21):
    """等間隔の行で (cv y, 左縁 cv x, 右縁 cv x) を出す。"""
    _, _, y0, y1 = bbox(p)
    row = {}
    for y, x in p:
        t = row.get(y)
        row[y] = (x, x) if t is None else (min(t[0], x), max(t[1], x))
    ys = sorted(row)
    out = []
    for i in range(samples):
        y = y0 + int((y1 - 1 - y0) * i / (samples - 1))
        y = min(ys, key=lambda v: abs(v - y))
        l, r = row[y]
        out.append(f"({y / H:.4f}: {l / W:.4f}..{(r + 1) / W:.4f})")
    return " ".join(out)


mask = {n: cls == i for i, n in enumerate(names)}
golds = comps(mask["gold"], 200)
for i, g in enumerate(sorted(golds[:2], key=lambda p: p[:, 1].min())):
    describe(f"{'left' if i == 0 else 'right'} closed eye", g)
    print("  columns " + columns(g))
if len(golds) > 2:
    for g in golds[2:]:
        describe("  extra gold", g)
# 鼻と舌は同じ珊瑚色の系統なので、位置で分ける（鼻は上、舌は口の中）。
corals = comps(mask["coral"] | mask["pink"], 100)
for c in corals[:3]:
    label = "nose" if (bbox(c)[2] + bbox(c)[3]) / 2 / H < 0.6 else "tongue"
    describe(label, c)
    print("  rows " + rows_profile(c, 9))
    if label == "nose":
        print("  columns " + columns(c, 9))
maroons = comps(mask["maroon"], 100)
if maroons:
    describe("mouth interior (maroon)", maroons[0])
# 口の内側全体 = maroon + pink + 口の外接内の white/cream の小片（牙）
creams = comps(mask["cream"] | mask["white"], 60)
center = [c for c in creams if abs((bbox(c)[0] + bbox(c)[1]) / 2 - W / 2) < W * 0.12]
ids = {id(c) for c in center}
others = [c for c in creams if id(c) not in ids]
if center:
    outline = max(center, key=len)
    describe("mouth outline (cream)", outline)
    print("  outer columns " + columns(outline))
    print("  rows " + rows_profile(outline, 25))
    ox0, ox1, oy0, oy1 = bbox(outline)
    inside = np.zeros((H, W), bool)
    inside[oy0:oy1, ox0:ox1] = (mask["maroon"] | mask["pink"])[oy0:oy1, ox0:ox1]
    inner = comps(inside, 100)
    if inner:
        describe("mouth inner region (maroon+pink)", inner[0])
        print("  inner columns " + columns(inner[0]))
        print("  inner rows " + rows_profile(inner[0], 25))
    fangs = [c for c in center if c is not outline and oy0 <= bbox(c)[2] <= oy1]
    for f in sorted(fangs, key=lambda c: bbox(c)[0]):
        describe("fang", f)
        print("  rows " + rows_profile(f, 7))
whisk = sorted(others, key=lambda c: ((bbox(c)[0] + bbox(c)[1]) / 2 > W / 2, bbox(c)[2]))
for i, c in enumerate(whisk):
    side = "left" if (bbox(c)[0] + bbox(c)[1]) / 2 < W / 2 else "right"
    describe(f"{side} whisker {i % 3 + 1}", c)
    print("  columns " + columns(c, 9))

if crop_dir:
    os.makedirs(crop_dir, exist_ok=True)
    def crop(name, x0, x1, y0, y1, s):
        box = (int(x0 * W), int(y0 * H), int(x1 * W), int(y1 * H))
        im.crop(box).resize(((box[2] - box[0]) * s, (box[3] - box[1]) * s), Image.NEAREST).save(f"{crop_dir}/{name}.png")
    crop("mouth-x2", 0.33, 0.67, 0.40, 0.96, 2)
    crop("left-eye-x3", 0.14, 0.42, 0.30, 0.50, 3)
    crop("nose-x4", 0.42, 0.58, 0.40, 0.58, 4)
