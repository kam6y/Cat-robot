"""眠りの Z の右移動の確認。PREV は移す前の静止版、NEW は今の版（どちらも scripts/render_face.sh preview の出力）。
Z 全体のずれ、形の一致、顔（Z の領域の外）の不変、ほかの表情の画素一致を出し、比較画像を OUT へ書く。PIL と numpy が要る。
usage: /usr/bin/python3 shift_check.py PREV_DIR NEW_DIR OUT_DIR"""
import os, sys
import numpy as np
from PIL import Image
prev, new, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
def load(p): return np.asarray(Image.open(p).convert("RGB")).astype(int)
def blue(a): return (a[..., 2] > 90) & (a[..., 2] > a[..., 0] + 40) & (a[..., 2] > a[..., 1] + 10)
def bbox(m):
    ys, xs = np.nonzero(m); return xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
W, H = 1280, 720
p = load(f"{prev}/canvas-sleeping-closed.png"); n = load(f"{new}/canvas-sleeping-closed.png")
bp, bn = bbox(blue(p)), bbox(blue(n))
print(f"Z group bbox prev x {bp[0]}..{bp[1]} y {bp[2]}..{bp[3]} | new x {bn[0]}..{bn[1]} y {bn[2]}..{bn[3]} | shift x {bn[0]-bp[0]:+d}/{bn[1]-bp[1]:+d} px (0.035*1280 = 44.8) y {bn[2]-bp[2]:+d}/{bn[3]-bp[3]:+d}")
print(f"new right edge cv {bn[1]/W:.4f}")
# shape identical after shift: shift prev blue mask by 45 px and compare
sh = 45
mp = blue(p); mn = blue(n)
moved = np.zeros_like(mp); moved[:, sh:] = mp[:, :-sh]
print(f"Z mask after +{sh}px shift: IoU {(moved & mn).sum() / (moved | mn).sum():.4f}")
# face unchanged: non-blue pixels outside both Z regions
zone = np.zeros((H, W), bool)
for b in (bp, bn): zone[max(0, b[2]-3):b[3]+3, max(0, b[0]-3):b[1]+3] = True
d = np.abs(p - n).max(axis=2)
print(f"sleeping canvas prev vs new: changed px outside the old+new Z regions {((d > 0) & ~zone).sum()}")
# Z crop: before (top) and after (bottom), x2
box = (int(0.72 * W), int(0.05 * H), int(0.98 * W), int(0.36 * H))
crops = [Image.fromarray(x.astype(np.uint8)).crop(box) for x in (p, n)]
cw, ch = crops[0].size; s = 2
pair = Image.new("RGB", (cw * s, ch * s * 2 + 4), (90, 90, 90))
for i, c in enumerate(crops): pair.paste(c.resize((cw * s, ch * s), Image.NEAREST), (0, i * (ch * s + 4)))
pair.save(f"{out}/zzz-crop-prev-new-x2.png")
# prev vs new full compare
full = Image.new("RGB", (W, H * 2 + 2), (90, 90, 90))
full.paste(Image.fromarray(p.astype(np.uint8)), (0, 0)); full.paste(Image.fromarray(n.astype(np.uint8)), (0, H + 2))
full.save(f"{out}/compare-prev-new.png")
# other expressions identical
names = sorted(f for f in os.listdir(prev) if f.endswith(".png"))
same = [f for f in names if os.path.exists(f"{new}/{f}") and np.array_equal(load(f"{prev}/{f}"), load(f"{new}/{f}"))]
print(f"prev vs new: {len(same)}/{len(names)} identical; differ: {sorted(set(names) - set(same))}")
