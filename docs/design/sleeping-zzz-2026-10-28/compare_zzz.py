"""眠りの Z の比較: 参照（1280x720 に縮小）と描画の青マスクの IoU・外接・色、Z 領域の外の不変、baseline との画素一致を出し、
比較画像を OUT_DIR へ書く。BASELINE_DIR と ROUND_DIR は scripts/render_face.sh preview の出力。PIL と numpy が要る。
usage: /usr/bin/python3 compare_zzz.py REFERENCE BASELINE_DIR ROUND_DIR OUT_DIR"""
import os, sys
import numpy as np
from PIL import Image

ref_path, base_dir, round_dir, out_dir = sys.argv[1:5]
os.makedirs(out_dir, exist_ok=True)
W, H = 1280, 720
ref = Image.open(ref_path).convert("RGB")
ref_small = ref.resize((W, H), Image.LANCZOS)
ren = Image.open(f"{round_dir}/canvas-sleeping-closed.png").convert("RGB")
base = Image.open(f"{base_dir}/canvas-sleeping-closed.png").convert("RGB")
assert ren.size == (W, H), ren.size

def blue_mask(im):
    a = np.asarray(im).astype(int)
    return (a[..., 2] > 90) & (a[..., 2] > a[..., 0] + 40) & (a[..., 2] > a[..., 1] + 10)

# Z region (canvas units) with a margin
zx0, zx1, zy0, zy1 = 0.73, 0.935, 0.07, 0.35
box = (int(zx0 * W), int(zy0 * H), int(zx1 * W), int(zy1 * H))
mr = blue_mask(ref_small); mn = blue_mask(ren)
inter = (mr & mn).sum(); union = (mr | mn).sum()
print(f"blue IoU ref(1280x720) vs rendered: {inter / union:.4f}  (ref px {mr.sum()}, rendered px {mn.sum()}, xor {(mr ^ mn).sum()})")
# blue outside the Z region
outside = mn.copy(); outside[box[1]:box[3], box[0]:box[2]] = False
print(f"rendered blue px outside Z region: {outside.sum()}")

# per-Z IoU and bbox diffs (connected by x ranges)
def comps(mask):
    from collections import deque
    H_, W_ = mask.shape; seen = np.zeros_like(mask); out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]: continue
        q = deque([(y0, x0)]); seen[y0, x0] = True; pts = []
        while q:
            y, x = q.popleft(); pts.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < H_ and 0 <= xx < W_ and mask[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True; q.append((yy, xx))
        if len(pts) > 50: out.append(np.array(pts))
    out.sort(key=lambda a: a[:, 1].min())
    return out
cr = comps(mr); cn = comps(mn)
for i, (a, b) in enumerate(zip(cr, cn)):
    ba = (a[:, 1].min(), a[:, 1].max() + 1, a[:, 0].min(), a[:, 0].max() + 1)
    bb = (b[:, 1].min(), b[:, 1].max() + 1, b[:, 0].min(), b[:, 0].max() + 1)
    sa = set(map(tuple, a)); sb = set(map(tuple, b))
    print(f"Z{i+1}: IoU {len(sa & sb) / len(sa | sb):.4f} px ref {len(sa)} rendered {len(sb)} | bbox diff (rendered - ref, px@1280x720) "
          f"x {bb[0]-ba[0]:+d}/{bb[1]-ba[1]:+d} y {bb[2]-ba[2]:+d}/{bb[3]-ba[3]:+d}")
an = np.asarray(ren).astype(int)
core = mn.copy()
for dy in range(-2, 3):
    for dx in range(-2, 3):
        core &= np.roll(np.roll(mn, dy, 0), dx, 1)
med = np.median(an[core], axis=0).astype(int) if core.any() else None
print(f"rendered Z core color median #{med[0]:02X}{med[1]:02X}{med[2]:02X}" if med is not None else "no core")

# baseline vs rendered outside the Z region
b = np.asarray(base).astype(int); n = an
d = np.abs(b - n).max(axis=2)
d_out = d.copy(); d_out[box[1]:box[3], box[0]:box[2]] = 0
print(f"sleeping canvas vs baseline: changed px total {(d > 0).sum()}, outside Z region {(d_out > 0).sum()} (max diff outside {d_out.max()})")

# images: crop compare (ref top, rendered bottom) scaled x3, overlay, diff
crop_r = ref_small.crop(box); crop_n = ren.crop(box)
cw, ch = crop_r.size; s = 3
cmp_img = Image.new("RGB", (cw * s, ch * s * 2 + 4), (90, 90, 90))
cmp_img.paste(crop_r.resize((cw * s, ch * s), Image.NEAREST), (0, 0))
cmp_img.paste(crop_n.resize((cw * s, ch * s), Image.NEAREST), (0, ch * s + 4))
cmp_img.save(f"{out_dir}/zzz-crop-compare-x3.png")
# outline overlay: ref mask red, rendered mask green, both = yellow
ov = np.zeros((ch, cw, 3), np.uint8)
mrc = mr[box[1]:box[3], box[0]:box[2]]; mnc = mn[box[1]:box[3], box[0]:box[2]]
ov[mrc & ~mnc] = (255, 60, 60); ov[mnc & ~mrc] = (60, 255, 60); ov[mrc & mnc] = (110, 110, 140)
Image.fromarray(ov).resize((cw * s, ch * s), Image.NEAREST).save(f"{out_dir}/zzz-crop-mask-diff-x3.png")
full = Image.new("RGB", (W, H * 2 + 2), (90, 90, 90)); full.paste(ref_small, (0, 0)); full.paste(ren, (0, H + 2))
full.save(f"{out_dir}/compare-full.png")
Image.blend(ref_small, ren, 0.5).save(f"{out_dir}/overlay-full.png")
diffimg = np.clip(np.abs(np.asarray(ref_small).astype(int) - an) * 2, 0, 255).astype(np.uint8)
Image.fromarray(diffimg).save(f"{out_dir}/diff-full.png")

# other expressions identical to baseline
names = sorted(f for f in os.listdir(base_dir) if f.endswith(".png"))
changed = []
for f in names:
    p2 = f"{round_dir}/{f}"
    if not os.path.exists(p2): changed.append((f, "missing")); continue
    x = np.asarray(Image.open(f"{base_dir}/{f}").convert("RGBA")).astype(int)
    y = np.asarray(Image.open(p2).convert("RGBA")).astype(int)
    if x.shape != y.shape: changed.append((f, "shape")); continue
    c = (np.abs(x - y).max(axis=2) > 0)
    if c.any():
        ys, xs = np.nonzero(c)
        changed.append((f, f"{c.sum()} px, bbox x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()} of {x.shape[1]}x{x.shape[0]}"))
print(f"baseline vs round: {len(names) - len(changed)}/{len(names)} images pixel-identical; changed:")
for f, why in changed:
    print(f"  {f}: {why}")
