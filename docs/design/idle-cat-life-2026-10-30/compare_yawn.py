"""あくびの比較: 参考 yawn-reference.png（1280×720 に縮小）と描画 canvas-yawning-closed.png の色分類ごとの IoU（全体と部位ごと）、
部位ごとの外接（キャンバス単位と px@1280×720 の差）、ひげの列ごとの中心 y の差、baseline（scripts/render_face.sh preview の
出力 37 枚）との画素一致を出す。PIL と numpy が要る。
usage: /usr/bin/python3 compare_yawn.py REFERENCE YAWN_DIR BASELINE_DIR PREVIEW_DIR
  YAWN_DIR は scripts/render_face.sh yawn の出力、PREVIEW_DIR は変更後の scripts/render_face.sh preview の出力。"""
import os, sys
from collections import deque
import numpy as np
from PIL import Image

ref_path, yawn_dir, base_dir, preview_dir = sys.argv[1:5]
W, H = 1280, 720
A = W / H
PROTOS = {"black": (6, 5, 5), "gold": (247, 196, 62), "cream": (249, 233, 203), "coral": (250, 135, 110),
          "maroon": (58, 26, 30), "pink": (240, 135, 135), "white": (252, 251, 249)}
names = list(PROTOS)
protos = np.array([PROTOS[n] for n in names])


def classify(im):
    a = np.asarray(im).astype(int)
    d = ((a[..., None, :] - protos[None, None, :, :]) ** 2).sum(-1)
    cls = d.argmin(-1)
    cls[d.min(-1) > 60 ** 2] = -1
    return {n: cls == i for i, n in enumerate(names)}


def comps(mask, minimum=30):
    seen = np.zeros_like(mask); out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]: continue
        q = deque([(y0, x0)]); seen[y0, x0] = True; pts = []
        while q:
            y, x = q.popleft(); pts.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < mask.shape[0] and 0 <= xx < mask.shape[1] and mask[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True; q.append((yy, xx))
        if len(pts) >= minimum: out.append(np.array(pts))
    out.sort(key=lambda p: -len(p))
    return out


def bbox(p, w, h):
    """キャンバス単位の (x0, x1, y0, y1)。"""
    return (p[:, 1].min() / w, (p[:, 1].max() + 1) / w, p[:, 0].min() / h, (p[:, 0].max() + 1) / h)


def flood(blocked, box, start):
    reach = np.zeros_like(blocked)
    q = deque([start]); reach[start] = True
    y0, y1, x0, x1 = box
    while q:
        y, x = q.popleft()
        for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
            if y0 <= yy < y1 and x0 <= xx < x1 and not reach[yy, xx] and not blocked[yy, xx]:
                reach[yy, xx] = True; q.append((yy, xx))
    return reach


def features(im):
    """部位ごとの外接（キャンバス単位）と、ひげの列ごとの中心 y（640 列の刻み）。画像はその解像度のまま測る。"""
    w, h = im.size
    m = classify(im)
    out = {}
    golds = sorted(comps(m["gold"], 200)[:2], key=lambda p: p[:, 1].min())
    for side, g in zip(("left", "right"), golds):
        out[f"{side} closed eye"] = bbox(g, w, h)
    # 口: クリーム色の輪郭に囲まれた領域（牙を含む）
    ring = m["cream"] | m["white"]
    box = (int(0.50 * h), int(0.95 * h), int(0.34 * w), int(0.66 * w))
    sub = np.zeros_like(ring); sub[box[0]:box[1], box[2]:box[3]] = True
    ring &= sub
    hull = sub & ~flood(ring, box, (box[0], box[2]))
    interior = hull & ~ring
    hp = np.array(list(zip(*np.nonzero(hull))))
    out["mouth outline (outer)"] = bbox(hp, w, h)
    ip = np.array(list(zip(*np.nonzero(interior))))
    out["mouth inside"] = bbox(ip, w, h)
    oc = {}
    for y, x in zip(*np.nonzero(hull)):
        t = oc.get(x); oc[x] = (y, y) if t is None else (min(t[0], y), max(t[1], y))
    ic = {}
    for y, x in zip(*np.nonzero(interior)):
        t = ic.get(x); ic[x] = (y, y) if t is None else (min(t[0], y), max(t[1], y))
    bottom_t = [(oc[x][1] - ic[x][1]) for x in oc if x in ic and 0.45 * w < x < 0.55 * w]
    thick = float(np.median(bottom_t))
    out["mouth outline thickness (cv H)"] = thick / h
    # 牙: 唇の内側の縁より下のクリーム色（trace_yawn.py と同じ範囲）
    for side in ("left", "right"):
        mask = np.zeros_like(ring)
        for y, x in zip(*np.nonzero(ring & hull)):
            xc = x if side == "left" else w - 1 - x
            if x in oc and y > oc[x][0] + 1.25 * thick and y < 0.66 * h and 0.424 * w < xc < 0.456 * w:
                mask[y, x] = True
        fp = np.array(list(zip(*np.nonzero(mask))))
        if len(fp): out[f"{side} fang (below the lip)"] = bbox(fp, w, h)
    # 舌: 口の中の珊瑚色の最大成分。鼻: 口より上の珊瑚色の最大成分。
    coral = m["coral"] | m["pink"]
    tongue = comps(coral & interior, 100)
    if tongue: out["tongue"] = bbox(tongue[0], w, h)
    above = coral.copy(); above[int(0.6 * h):] = False
    nose = comps(above, 100)
    if nose: out["nose"] = bbox(nose[0], w, h)
    # ひげ: 口の外のクリーム色（左→右、上→下）
    # ひげの端は白に分類される画素を含むので、クリームと白の両方を取る（trace_yawn.py と同じ）。
    outside = (m["cream"] | m["white"]) & ~hull
    outside[:, int(0.3 * w):int(0.7 * w)] = False
    whisk = comps(outside, 300)
    whisk.sort(key=lambda p: (p[:, 1].mean() > w / 2, p[:, 0].min()))
    centerlines = {}
    for i, p in enumerate(whisk):
        side = "left" if p[:, 1].mean() < w / 2 else "right"
        name = f"{side} whisker {i % 3 + 1}"
        out[name] = bbox(p, w, h)
        sums = {}
        for y, x in p:
            b = int((x + 0.5) / w * 640)
            s = sums.get(b, (0.0, 0)); sums[b] = (s[0] + (y + 0.5) / h, s[1] + 1)
        centerlines[name] = {b: s[0] / s[1] for b, s in sums.items()}
    return out, centerlines, m


ref = Image.open(ref_path).convert("RGB")
ref_small = ref.resize((W, H), Image.LANCZOS)
ren = Image.open(f"{yawn_dir}/canvas-yawning-closed.png").convert("RGB")
assert ren.size == (W, H), ren.size

print("== color-class IoU reference(1280x720) vs rendered, by region (ref px, rendered px)")
mr = classify(ref_small); mn = classify(ren)
regions = {"whole": np.ones((H, W), bool)}
eyes = np.zeros((H, W), bool); eyes[: int(0.5 * H)] = True
mouth = np.zeros((H, W), bool); mouth[int(0.5 * H):, int(0.34 * W):int(0.66 * W)] = True
whisk = np.zeros((H, W), bool); whisk[int(0.4 * H):] = True; whisk[:, int(0.34 * W):int(0.66 * W)] = False
regions.update({"eyes (y<0.5)": eyes, "mouth (|x-0.5|<0.16, y>0.5)": mouth, "whiskers (outside, y>0.4)": whisk})
classes = {"gold": mr["gold"], "cream": mr["cream"] | mr["white"], "coral+pink": mr["coral"] | mr["pink"], "maroon": mr["maroon"]}
classes_n = {"gold": mn["gold"], "cream": mn["cream"] | mn["white"], "coral+pink": mn["coral"] | mn["pink"], "maroon": mn["maroon"]}
for rname, region in regions.items():
    parts = []
    for cname in classes:
        a = classes[cname] & region; b = classes_n[cname] & region
        u = (a | b).sum()
        if u == 0: continue
        parts.append(f"{cname} {(a & b).sum() / u:.3f} ({a.sum()}, {b.sum()})")
    print(f"  {rname}: " + "; ".join(parts))

print("== feature bounds: reference (own resolution) vs rendered, canvas units; diff rendered - reference in px@1280x720")
fr, cr, _ = features(ref)
fn, cn, _ = features(ren)
for name in fr:
    if name not in fn:
        print(f"  {name}: missing in rendered"); continue
    a, b = fr[name], fn[name]
    if isinstance(a, float):
        print(f"  {name}: ref {a:.4f} rendered {b:.4f} (production mouthLineWidth 0.0185)"); continue
    print(f"  {name}: ref x {a[0]:.4f}..{a[1]:.4f} y {a[2]:.4f}..{a[3]:.4f} | rendered x {b[0]:.4f}..{b[1]:.4f} y {b[2]:.4f}..{b[3]:.4f}"
          f" | diff px x {(b[0] - a[0]) * W:+.1f}/{(b[1] - a[1]) * W:+.1f} y {(b[2] - a[2]) * H:+.1f}/{(b[3] - a[3]) * H:+.1f}")
for name in fn:
    if name not in fr: print(f"  {name}: only in rendered")
print("== whisker centerline dy (rendered - reference) over shared 640-columns, px@720")
for name in sorted(cr):
    if name not in cn: continue
    shared = sorted(set(cr[name]) & set(cn[name]))
    d = [(cn[name][b] - cr[name][b]) * H for b in shared]
    if d:
        print(f"  {name}: mean {np.mean(d):+.2f} max |dy| {np.max(np.abs(d)):.2f} over {len(d)} columns"
              f" (reference spans {len(cr[name])} columns, rendered {len(cn[name])})")

print("== baseline identity (37 preview files; byte-identical, else differing px count and max |diff|)")
same = 0; different = []
for fname in sorted(os.listdir(base_dir)):
    if not fname.endswith(".png"): continue
    pa, pb = f"{base_dir}/{fname}", f"{preview_dir}/{fname}"
    if not os.path.exists(pb):
        different.append(f"{fname}: missing"); continue
    if open(pa, "rb").read() == open(pb, "rb").read():
        same += 1; continue
    a = np.asarray(Image.open(pa).convert("RGB")).astype(int)
    b = np.asarray(Image.open(pb).convert("RGB")).astype(int)
    d = np.abs(a - b).max(-1)
    different.append(f"{fname}: {int((d > 0).sum())} px differ, max |diff| {int(d.max())}")
print(f"  identical {same}, different {len(different)}")
for line in different: print("  " + line)
