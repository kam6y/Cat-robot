"""あくびの参考画像から、描画に使う 3 次ベジェの制御点を当てはめる（CatFaceShapes.swift の yawn の定数の根拠）。
- 閉じた目の弧: 左右の弧の列ごとの上縁・下縁を製品の目の枠（neutral の EyeFrame）の局所座標 (u: 鼻側が正, v: 下が正) に写し、
  左右を平均してから、頂点で水平に接する 2 本ずつの 3 次ベジェ（上縁・下縁）を最小二乗で当てはめる。
- 口: クリーム色の輪郭の外縁を輪郭追跡で順にたどり、線幅の半分だけ内側へずらした中心線を、x または y の極値で区切った
  3 次ベジェ（極値で水平・垂直に接する。上中央は尖り）に実寸で当てはめ、残差が大きい区間は接線を共有して二つに分ける。
  左半分だけ（右は鏡映）。
- 牙: 上唇の内側の縁から垂れる小片の左右の縁を 3 次ベジェで当てはめる。舌: 上縁の弧（壁との接点 → 中央で水平）。
- 鼻・ひげ: 製品の形からの移動量（鼻は下端基準の倍率も）。
最後に当てはめた形を同じ大きさに描き、色の分類ごとの IoU で参考画像と照合する。
usage: /usr/bin/python3 trace_yawn.py IMAGE [RASTER_OUT.png]"""
import sys
from collections import defaultdict, deque
import numpy as np
from PIL import Image, ImageDraw

im = Image.open(sys.argv[1]).convert("RGB")
W, H = im.size
A = W / H
a = np.asarray(im).astype(int)
PROTOS = {"black": (6, 5, 5), "gold": (247, 196, 62), "cream": (249, 233, 203), "coral": (250, 135, 110),
          "maroon": (58, 26, 30), "pink": (240, 135, 135), "white": (252, 251, 249)}
names = list(PROTOS)
protos = np.array([PROTOS[n] for n in names])
d = ((a[..., None, :] - protos[None, None, :, :]) ** 2).sum(-1)
cls = d.argmin(-1)
cls[d.min(-1) > 60 ** 2] = -1
m = {n: cls == i for i, n in enumerate(names)}

EYE_C = (0.2374, 0.4327)
EYE_R = (0.1247, 0.2231)
LINE = 0.0185  # 製品の口の線幅（キャンバス高さ比）


def fit(points, p0, p3, spec1=("free",), spec2=("free",)):
    """端点を固定した 3 次ベジェを点列に最小二乗で当てはめる（弦長パラメータ）。
    spec は制御点の拘束: ("free",) | ("x", 値) | ("y", 値) | ("dir", 起点, 向き)（起点から向きへ伸びる長さだけを解く）。
    返り値 (c1, c2, 点ごとの誤差)。座標系は呼び出し側のまま。"""
    pts = np.asarray(points, float)
    p0 = np.asarray(p0, float); p3 = np.asarray(p3, float)
    # 弦長パラメータは端点 p0・p3 からの距離を含めて取る（端点が点列から離れていてもよい）。
    chain = np.concatenate([[p0], pts, [p3]])
    seg = np.linalg.norm(np.diff(chain, axis=0), axis=1)
    t = np.concatenate([[0], np.cumsum(seg)]); t /= max(t[-1], 1e-9)
    t = t[1:-1]
    b0, b1, b2, b3 = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3

    def basis(spec):
        if spec[0] == "free": return np.zeros(2), np.eye(2)
        if spec[0] == "x": return np.array([spec[1], 0.0]), np.array([[0.0], [1.0]])
        if spec[0] == "y": return np.array([0.0, spec[1]]), np.array([[1.0], [0.0]])
        if spec[0] == "dir": return np.asarray(spec[1], float), np.asarray(spec[2], float).reshape(2, 1)
        raise ValueError(spec)
    base1, A1 = basis(spec1); base2, A2 = basis(spec2)
    rhs = pts - (np.outer(b0, p0) + np.outer(b3, p3) + np.outer(b1, base1) + np.outer(b2, base2))
    k1, k2 = A1.shape[1], A2.shape[1]
    n = len(t)
    M = np.zeros((2 * n, k1 + k2))
    M[:n, :k1] = np.outer(b1, A1[0]); M[:n, k1:] = np.outer(b2, A2[0])
    M[n:, :k1] = np.outer(b1, A1[1]); M[n:, k1:] = np.outer(b2, A2[1])
    theta = np.linalg.lstsq(M, np.concatenate([rhs[:, 0], rhs[:, 1]]), rcond=None)[0]
    c1 = base1 + A1 @ theta[:k1]; c2 = base2 + A2 @ theta[k1:]
    curve = np.outer(b0, p0) + np.outer(b1, c1) + np.outer(b2, c2) + np.outer(b3, p3)
    return c1, c2, np.linalg.norm(curve - pts, axis=1)


def bezier(p0, c1, c2, p3, t):
    s = 1 - t
    return (s ** 3)[:, None] * p0 + (3 * s * s * t)[:, None] * c1 + (3 * s * t * t)[:, None] * c2 + (t ** 3)[:, None] * p3


def column_edges(mask):
    col = {}
    for y, x in zip(*np.nonzero(mask)):
        t = col.get(x)
        col[x] = (y, y) if t is None else (min(t[0], y), max(t[1], y))
    return col


def row_edges(mask):
    row = {}
    for y, x in zip(*np.nonzero(mask)):
        t = row.get(y)
        row[y] = (x, x) if t is None else (min(t[0], x), max(t[1], x))
    return row


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


def cv(p):
    """実寸 (x*A, y) → キャンバス単位。"""
    return (p[0] / A, p[1])


def fmt(p):
    return f"CGPoint(x: {p[0]:.4f}, y: {p[1]:.4f})"


# ---------- 閉じた目の弧 ----------
print("== closed eye arcs (eye-local u,v of the production neutral eye frame; left/right averaged)")
gold = m["gold"]
profiles = []
for side, cx, sign in (("left", EYE_C[0], 1), ("right", 1 - EYE_C[0], -1)):
    half = gold.copy()
    if side == "left": half[:, W // 2:] = False
    else: half[:, : W // 2] = False
    col = column_edges(half)
    rows = []
    for x in sorted(col):
        top, bottom = col[x]
        u = sign * ((x + 0.5) / W - cx) / EYE_R[0]
        rows.append((u, (top / H - EYE_C[1]) / EYE_R[1], ((bottom + 1) / H - EYE_C[1]) / EYE_R[1]))
    rows.sort()
    profiles.append(np.array(rows))
u0 = max(p[:, 0].min() for p in profiles); u1 = min(p[:, 0].max() for p in profiles)
grid = np.linspace(u0, u1, 160)
up = np.mean([np.interp(grid, p[:, 0], p[:, 1]) for p in profiles], 0)
lo = np.mean([np.interp(grid, p[:, 0], p[:, 2]) for p in profiles], 0)
apex_i = int(np.argmin(up)); apex_u = grid[apex_i]
tip_o = (u0, float((up[0] + lo[0]) / 2)); tip_i = (u1, float((up[-1] + lo[-1]) / 2))
print(f"  outer tip ({tip_o[0]:.3f}, {tip_o[1]:.3f}) inner tip ({tip_i[0]:.3f}, {tip_i[1]:.3f}); apex u {apex_u:.3f}"
      f" upper v {up[apex_i]:.3f} lower v {lo[apex_i]:.3f} thickness {(lo[apex_i] - up[apex_i]) * EYE_R[1]:.4f} cv H")
arc_swift = {}
for name, edge in (("upper", up), ("lower", lo)):
    apex = (apex_u, float(edge[apex_i]))
    pts_o = np.stack([grid[: apex_i + 1], edge[: apex_i + 1]], 1)
    pts_i = np.stack([grid[apex_i:], edge[apex_i:]], 1)
    c1, c2, e1 = fit(pts_o, tip_o, apex, ("free",), ("y", apex[1]))
    c3, c4, e2 = fit(pts_i, apex, tip_i, ("y", apex[1]), ("free",))
    arc_swift[name] = (apex, c1, c2, c3, c4)
    print(f"  {name}: apex ({apex[0]:.3f}, {apex[1]:.3f}); outer -> apex c1 ({c1[0]:.3f}, {c1[1]:.3f}) c2 ({c2[0]:.3f}, {c2[1]:.3f})"
          f" rms {np.sqrt((e1 ** 2).mean()) * EYE_R[1] * H:.2f} px; apex -> inner c1 ({c3[0]:.3f}, {c3[1]:.3f}) c2 ({c4[0]:.3f}, {c4[1]:.3f})"
          f" rms {np.sqrt((e2 ** 2).mean()) * EYE_R[1] * H:.2f} px")

# ---------- 口の輪郭 ----------
print("== mouth outline centerline (canvas units, left half from the top center cusp to the bottom center)")
ring = m["cream"] | m["white"]
box = (int(0.50 * H), int(0.95 * H), int(0.34 * W), int(0.66 * W))
sub = np.zeros_like(ring); sub[box[0]:box[1], box[2]:box[3]] = True
ring &= sub
reach = flood(ring, box, (box[0], box[2]))
hull = sub & ~reach
interior = hull & ~ring
oc = column_edges(hull); ic = column_edges(interior)
orow = row_edges(hull); irow = row_edges(interior)
side_t = [(irow[y][0] - orow[y][0]) for y in orow if y in irow and 0.66 * H < y < 0.80 * H]
bottom_t = [(oc[x][1] - ic[x][1]) for x in oc if x in ic and 0.45 * W < x < 0.55 * W]
thick_px = float(np.median(bottom_t))
print(f"  outline thickness: side {np.median(side_t) / W * A:.4f} cv H, bottom {thick_px / H:.4f} cv H (production mouthLineWidth {LINE})")

xs_top = [x for x in oc if abs(x - W / 2) < 3]
start_x = min(xs_top, key=lambda x: oc[x][0]); start = (oc[start_x][0], start_x)
dirs = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]
def inside(p): return box[0] <= p[0] < box[1] and box[2] <= p[1] < box[3] and hull[p]
contour = [start]; cur = start; back = 6
for _ in range(60000):
    found = False
    for k in range(8):
        di = (back + 1 + k) % 8
        nxt = (cur[0] + dirs[di][0], cur[1] + dirs[di][1])
        if inside(nxt):
            contour.append(nxt); back = (di + 4) % 8; cur = nxt; found = True; break
    if not found or (cur == start and len(contour) > 10): break
contour = np.array(contour[:-1], float)
P = np.stack([(contour[:, 1] + 0.5) / W * A, (contour[:, 0] + 0.5) / H], 1)   # 実寸（高さ 1）
k = 9
Ps = np.array([np.roll(P, s, 0) for s in range(-k, k + 1)]).mean(0)
tan = np.roll(Ps, -3, 0) - np.roll(Ps, 3, 0)
tan /= np.linalg.norm(tan, axis=1, keepdims=True) + 1e-9
normal = np.stack([-tan[:, 1], tan[:, 0]], 1)
centroid = P.mean(0)
normal[((centroid - Ps) * normal).sum(1) < 0] *= -1
C = Ps + normal * (thick_px / H / 2)
order = np.where(C[:, 0] <= 0.5 * A)[0]
order = order[order > len(C) // 4]   # 追跡の開始点（上中央）そのものは除き、後半の左側の連続した区間だけを使う
seq = C[order][::-1]            # 上中央 → 左側 → 底中央
seq[0, 0] = 0.5 * A; seq[-1, 0] = 0.5 * A
S = np.array([np.roll(seq, s, 0) for s in range(-6, 7)]).mean(0); S[:6] = seq[:6]; S[-6:] = seq[-6:]
dx = np.gradient(S[:, 0]); dy = np.gradient(S[:, 1])
breaks = [(0, "cusp")]
for i in range(8, len(S) - 8):
    if dy[i - 1] * dy[i + 1] < 0 and abs(dx[i]) > abs(dy[i]) * 0.3 and i - breaks[-1][0] > 12:
        breaks.append((i, "H"))
    elif dx[i - 1] * dx[i + 1] < 0 and abs(dy[i]) > abs(dx[i]) * 0.3 and i - breaks[-1][0] > 12:
        breaks.append((i, "V"))
breaks.append((len(S) - 1, "H"))
print("  breakpoints:", " ".join(f"{k}({S[i][0] / A:.4f},{S[i][1]:.4f})" for i, k in breaks))

TOL = 1.6 / H   # 実寸（高さ 1）での許容 rms

def spec_for(kind, point):
    if kind == "H": return ("y", point[1])
    if kind == "V": return ("x", point[0])
    return ("free",)

def fit_segment(i0, k0, i1, k1, depth=0, dir0=None, dir1=None):
    """[i0, i1] を 1 本の 3 次ベジェで当てはめ、残差が大きければ接線を共有して二つに分ける。"""
    # 上中央の尖りの近くは法線のずれで中心線が乱れるので、最初の 16 点は当てはめに使わず、その近くでは分けない。
    lead = 16 if k0 == "cusp" else 0
    pts = seq[i0 + lead:i1 + 1]
    p0, p3 = S[i0], S[i1]
    s1 = ("dir", p0, dir0) if dir0 is not None else spec_for(k0, p0)
    s2 = ("dir", p3, dir1) if dir1 is not None else spec_for(k1, p3)
    c1, c2, err = fit(pts, p0, p3, s1, s2)
    rms = float(np.sqrt((err ** 2).mean()))
    if rms > TOL and depth < 2 and len(pts) > 24:
        low = max(8, 30 - lead)
        j = i0 + lead + low + int(np.argmax(err[low:-8]))
        tangent = S[min(j + 4, len(S) - 1)] - S[max(j - 4, 0)]
        tangent /= np.linalg.norm(tangent)
        return fit_segment(i0, k0, j, "J", depth + 1, dir0, -tangent) + fit_segment(j, "J", i1, k1, depth + 1, tangent, dir1)
    return [(p0, c1, c2, p3, rms, len(pts))]

segments = []
for (i0, k0), (i1, k1) in zip(breaks, breaks[1:]):
    segments += fit_segment(i0, k0, i1, k1)
print(f"  {len(segments)} cubic(s); swift (left half, from top center):")
print(f"    .move({fmt(cv(segments[0][0]))}),")
for p0, c1, c2, p3, rms, n in segments:
    print(f"    .curve(to: {fmt(cv(p3))}, control1: {fmt(cv(c1))}, control2: {fmt(cv(c2))}),   // rms {rms * H:.2f} px n {n}")

def flatten(segs, n=64):
    out = []
    for p0, c1, c2, p3, *_ in segs:
        out.append(bezier(p0, c1, c2, p3, np.linspace(0, 1, n)))
    return np.concatenate(out)
center_poly = flatten(segments)

# ---------- 牙 ----------
print("== fangs (canvas units; left fang, right is mirrored)")
fang_swift = []
for side in ("left", "right"):
    mask = np.zeros_like(ring)
    for y, x in zip(*np.nonzero(ring & hull)):
        xc = x if side == "left" else W - 1 - x
        # 牙は上唇のくぼみの底（x 0.44 付近）から垂れる。唇の内側の縁（外縁 + 線幅）より下だけを取り、口角の瘤と唇の斜めの部分は x で除く。
        if x in oc and y > oc[x][0] + 1.25 * thick_px and y < 0.66 * H and 0.424 * W < xc < 0.456 * W:
            mask[y, x] = True
    rows = row_edges(mask)
    widest_w = max(r[1] - r[0] for r in rows.values())
    # 唇の内側の縁の丸みが残る上の細い行（最初に最大幅の 40% 以上になる行より上）は牙ではないので除く。先端の細い行は残す。
    first_wide = min(y for y, r in rows.items() if r[1] - r[0] >= 0.4 * widest_w)
    rows = {y: r for y, r in rows.items() if y >= first_wide}
    ys = sorted(rows)
    tip_y = ys[-1]; tip_x = (rows[tip_y][0] + rows[tip_y][1] + 1) / 2
    top = ys[0]
    cx = int((rows[top][0] + rows[top][1] + 1) / 2)
    inner_y = oc[cx][0] + thick_px
    center_y = oc[cx][0] + thick_px / 2
    print(f"  {side}: rows {top / H:.4f}..{(tip_y + 1) / H:.4f}, tip ({tip_x / W:.4f}, {(tip_y + 1) / H:.4f}), top row x {rows[top][0] / W:.4f}..{(rows[top][1] + 1) / W:.4f},"
          f" lip inner edge y {inner_y / H:.4f}, lip centerline y {center_y / H:.4f}")
    for y in ys[::5]:
        print(f"    y {y / H:.4f}: x {rows[y][0] / W:.4f}..{(rows[y][1] + 1) / W:.4f} w {(rows[y][1] + 1 - rows[y][0]) / W * A:.4f} cvH")
    if side == "right": continue
    left_edge = np.array([[rows[y][0] / W * A, (y + 0.5) / H] for y in ys])
    right_edge = np.array([[(rows[y][1] + 1) / W * A, (y + 0.5) / H] for y in ys])
    tip = np.array([tip_x / W * A, (tip_y + 1) / H])
    out = []
    for name, edge in (("outer", left_edge), ("inner", right_edge)):
        head = edge[:8]
        slope = np.polyfit(head[:, 1], head[:, 0], 1)
        base = np.array([np.polyval(slope, center_y / H), center_y / H])
        c1, c2, err = fit(edge, base, tip, ("free",), ("free",))
        out.append((base, c1, c2))
        print(f"  {name} edge: base {fmt(cv(base))} c1 {fmt(cv(c1))} c2 {fmt(cv(c2))} -> tip {fmt(cv(tip))} rms {np.sqrt((err ** 2).mean()) * H:.2f} px")
    fang_swift = [(out[0][0], out[0][1], out[0][2], tip), (tip, out[1][2], out[1][1], out[1][0])]
    print("  swift (left fang; outer edge down to the tip, inner edge back up):")
    print(f"    .move({fmt(cv(out[0][0]))}),")
    print(f"    .curve(to: {fmt(cv(tip))}, control1: {fmt(cv(out[0][1]))}, control2: {fmt(cv(out[0][2]))}),")
    print(f"    .curve(to: {fmt(cv(out[1][0]))}, control1: {fmt(cv(out[1][2]))}, control2: {fmt(cv(out[1][1]))}),")

# ---------- 舌 ----------
print("== tongue (canvas units; top edge from the wall contact on the outline centerline to the apex)")
tongue_all = (m["coral"] | m["pink"]) & interior
# 舌は珊瑚色の最大の連結成分（牙や縁のにじみの画素を除く）
seen = np.zeros_like(tongue_all); best_comp = None
for y0, x0 in zip(*np.nonzero(tongue_all)):
    if seen[y0, x0]: continue
    q = deque([(y0, x0)]); seen[y0, x0] = True; pts_c = []
    while q:
        y, x = q.popleft(); pts_c.append((y, x))
        for dy_ in (-1, 0, 1):
            for dx_ in (-1, 0, 1):
                yy, xx = y + dy_, x + dx_
                if 0 <= yy < H and 0 <= xx < W and tongue_all[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True; q.append((yy, xx))
    if best_comp is None or len(pts_c) > len(best_comp): best_comp = pts_c
tongue = np.zeros_like(tongue_all)
for y, x in best_comp: tongue[y, x] = True
tc = column_edges(tongue)
txs = sorted(tc)
contact_y = tc[txs[0]][0] / H
print(f"  bbox cv x {txs[0] / W:.4f}..{(txs[-1] + 1) / W:.4f} y {min(v[0] for v in tc.values()) / H:.4f}..{(max(v[1] for v in tc.values()) + 1) / H:.4f}; wall contact y {contact_y:.4f}")
# 輪郭の中心線上で y = contact_y の点（最も幅の広い点より下の区間から探す）
contact = None
for seg_i in range(len(segments) - 1, -1, -1):
    sp0, sc1, sc2, sp3 = segments[seg_i][:4]
    if sp0[1] <= contact_y <= sp3[1]:
        lo_t, hi_t = 0.0, 1.0
        for _ in range(40):
            mid = (lo_t + hi_t) / 2
            if bezier(sp0, sc1, sc2, sp3, np.array([mid]))[0][1] < contact_y: lo_t = mid
            else: hi_t = mid
        contact = bezier(sp0, sc1, sc2, sp3, np.array([(lo_t + hi_t) / 2]))[0]
        print(f"  contact lies on outline segment {seg_i} at t {(lo_t + hi_t) / 2:.3f}")
        break
top_pts = np.array([[(x + 0.5) / W * A, tc[x][0] / H] for x in txs if (x + 0.5) / W <= 0.5])
apex = np.array([0.5 * A, top_pts[-1][1]])
c1, c2, err = fit(top_pts, contact, apex, ("free",), ("y", apex[1]))
print(f"  contact on centerline {fmt(cv(contact))}; apex {fmt(cv(apex))};"
      f" c1 {fmt(cv(c1))} c2 {fmt(cv(c2))} rms {np.sqrt((err ** 2).mean()) * H:.2f} px")
print("  swift (tongue top edge, left half; close below and clip to the outline):")
print(f"    .move({fmt(cv(contact))}),")
print(f"    .curve(to: {fmt(cv(apex))}, control1: {fmt(cv(c1))}, control2: {fmt(cv(c2))}),")
tongue_swift = (contact, c1, c2, apex)

# ---------- 色 ----------
for name, mask, off in (("tongue", tongue, 3), ("maroon", m["maroon"], 2), ("gold", m["gold"], 2), ("cream", ring, 2)):
    core = mask.copy()
    for dy_ in range(-off, off + 1):
        for dx_ in range(-off, off + 1):
            core &= np.roll(np.roll(mask, dy_, 0), dx_, 1)
    med = np.median(a[core], 0).astype(int)
    print(f"== color {name} core median #{med[0]:02X}{med[1]:02X}{med[2]:02X} (n {core.sum()})")

# ---------- 鼻 ----------
nose = m["coral"].copy(); nose[int(0.6 * H):] = False
core = nose.copy()
for dy_ in range(-3, 4):
    for dx_ in range(-3, 4):
        core &= np.roll(np.roll(nose, dy_, 0), dx_, 1)
med = np.median(a[core], 0).astype(int)
nr = row_edges(nose)
ny = sorted(nr); widest = max(ny, key=lambda y: nr[y][1] - nr[y][0])
top_, bottom_ = ny[0] / H, (ny[-1] + 1) / H
width_ = (nr[widest][1] + 1 - nr[widest][0]) / W
print(f"== nose: top {top_:.4f} bottom {bottom_:.4f} height {bottom_ - top_:.4f} widest row y {widest / H:.4f} x {nr[widest][0] / W:.4f}..{(nr[widest][1] + 1) / W:.4f}"
      f" (width {width_:.4f}) color #{med[0]:02X}{med[1]:02X}{med[2]:02X}")
print(f"  production top 0.6163 bottom 0.7045 height 0.0882 width 0.0796 -> bottom shift {bottom_ - 0.7045:+.4f}, scale {(bottom_ - top_) / 0.0882:.3f} (height) {width_ / 0.0796:.3f} (width)")

# ---------- ひげ ----------
print("== whiskers: production centerline (neutral spec) shifted by dy and rotated about the root; sleepy already lifts -7 deg")
specs = [((0.2402, 0.7138), (0.1785, 0.6704), (0.1068, 0.6514), (0.0420, 0.6853)),
         ((0.2585, 0.7445), (0.1915, 0.7263), (0.1172, 0.7328), (0.0570, 0.7913)),
         ((0.2571, 0.7872), (0.2004, 0.7879), (0.1429, 0.8112), (0.0993, 0.8761))]
# ひげの端は白に分類される画素（例: 左下の根元 RGB 255,250,234）を含むので、クリームと白の両方を取る。
cream_w = (m["cream"] | m["white"]) & ~hull
cream_w[:, int(0.3 * W):int(0.7 * W)] = False
cream_w[int(0.75 * H):] = False
seen = np.zeros_like(cream_w); comps = []
for y0, x0 in zip(*np.nonzero(cream_w)):
    if seen[y0, x0]: continue
    q = deque([(y0, x0)]); seen[y0, x0] = True; pts_c = []
    while q:
        y, x = q.popleft(); pts_c.append((y, x))
        for dy_ in (-1, 0, 1):
            for dx_ in (-1, 0, 1):
                yy, xx = y + dy_, x + dx_
                if 0 <= yy < H and 0 <= xx < W and cream_w[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True; q.append((yy, xx))
    if len(pts_c) > 500: comps.append(np.array(pts_c))
lefts = sorted([c for c in comps if c[:, 1].mean() < W / 2], key=lambda c: c[:, 0].min())
def rot(p, o, ang):
    dx_ = (p[0] - o[0]) * A; dy_ = p[1] - o[1]
    return (o[0] + (dx_ * np.cos(ang) - dy_ * np.sin(ang)) / A, o[1] + dx_ * np.sin(ang) + dy_ * np.cos(ang))
for idx, (comp, spec) in enumerate(zip(lefts, specs)):
    col = defaultdict(list)
    for y, x in comp: col[x].append(y)
    ref = {x: (np.mean(ys) + 0.5) / H for x, ys in col.items()}
    best = None
    for dy_ in np.arange(-0.24, -0.12, 0.001):
        for deg in np.arange(-12, 12.1, 0.5):
            ang = np.deg2rad(deg)
            root = np.array(spec[0])
            c1 = np.array(rot(spec[1], root, ang)); c2 = np.array(rot(spec[2], root, ang)); tip = np.array(rot(spec[3], root, ang))
            curve = bezier(root, c1, c2, tip, np.linspace(0, 1, 60)); curve[:, 1] += dy_
            err = [(y - ref[int(x * W)]) * H for x, y in curve if int(x * W) in ref]
            if len(err) < 20: continue
            e = float(np.sqrt(np.mean(np.square(err))))
            if best is None or e < best[0]: best = (e, dy_, deg, len(err))
    bx0, bx1 = comp[:, 1].min() / W, (comp[:, 1].max() + 1) / W
    by0, by1 = comp[:, 0].min() / H, (comp[:, 0].max() + 1) / H
    print(f"  left whisker {idx + 1}: ref bbox x {bx0:.4f}..{bx1:.4f} y {by0:.4f}..{by1:.4f} (span {bx1 - bx0:.4f}; production root-tip {spec[0][0] - spec[3][0]:.4f})"
          f" | best dy {best[1]:+.3f} lift {best[2]:+.1f} deg ({best[2] + 7:+.1f} beyond sleepy) rms {best[0]:.2f} px over {best[3]} cols")

# ---------- 当てはめた形を描いて照合 ----------
if len(sys.argv) > 2:
    out = Image.new("RGB", (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(out)
    def px(points):
        return [(float(p[0] / A * W), float(p[1] * H)) for p in points]
    def mirror(points):
        return [(W - x, y) for x, y in points]
    left = px(center_poly)
    outline_poly = left + mirror(left)[::-1]
    draw.polygon(outline_poly, fill=PROTOS["maroon"])
    # 舌: 弧（接点 → 頂点 → 鏡映の接点）を下で閉じ、輪郭の内側（中心線のパス）で切り抜く
    contact, c1, c2, apex = tongue_swift
    arc_px = px(bezier(contact, c1, c2, apex, np.linspace(0, 1, 64)))
    tongue_poly = arc_px + mirror(arc_px)[::-1] + [(0.70 * W, contact[1] * H), (0.70 * W, 0.96 * H), (0.30 * W, 0.96 * H), (0.30 * W, contact[1] * H)]
    clip = Image.new("1", (W, H), 0); ImageDraw.Draw(clip).polygon(outline_poly, fill=1)
    tongue_im = Image.new("1", (W, H), 0); ImageDraw.Draw(tongue_im).polygon(tongue_poly, fill=1)
    out.paste(Image.new("RGB", (W, H), PROTOS["coral"]), (0, 0), Image.fromarray(np.asarray(clip) & np.asarray(tongue_im)))
    draw = ImageDraw.Draw(out)
    for s in (1, -1):
        fp = []
        for p0, c1_, c2_, p3 in fang_swift:
            fp += px(bezier(p0, c1_, c2_, p3, np.linspace(0, 1, 32)))
        draw.polygon(fp if s == 1 else mirror(fp), fill=PROTOS["cream"])
    draw.line(outline_poly + outline_poly[:2], fill=PROTOS["cream"], width=int(round(thick_px)), joint="curve")
    for cx, sign in ((EYE_C[0], 1), (1 - EYE_C[0], -1)):
        def to_px(uv):
            return [(float((cx + sign * u * EYE_R[0]) * W), float((EYE_C[1] + v * EYE_R[1]) * H)) for u, v in uv]
        ua = arc_swift["upper"]; la = arc_swift["lower"]
        t = np.linspace(0, 1, 64)
        poly = (to_px(bezier(np.array(tip_o), ua[1], ua[2], np.array(ua[0]), t)) + to_px(bezier(np.array(ua[0]), ua[3], ua[4], np.array(tip_i), t))
                + to_px(bezier(np.array(tip_i), la[4], la[3], np.array(la[0]), t)) + to_px(bezier(np.array(la[0]), la[2], la[1], np.array(tip_o), t)))
        draw.polygon(poly, fill=PROTOS["gold"])
    out.save(sys.argv[2])
    b = np.asarray(out).astype(int)
    def iou(ref_mask, color, region):
        drawn = (np.abs(b - np.array(color)).sum(-1) < 3) & region
        rm = ref_mask & region
        return (rm & drawn).sum() / max(1, (rm | drawn).sum()), rm.sum(), drawn.sum()
    mouth_region = np.zeros((H, W), bool); mouth_region[int(0.5 * H):, int(0.34 * W):int(0.66 * W)] = True
    eye_region = np.zeros((H, W), bool); eye_region[: int(0.5 * H)] = True
    print("== raster check (fitted vector shapes vs reference; IoU, reference px, drawn px)")
    for label, ref_mask, color, region in (("gold arcs", m["gold"], PROTOS["gold"], eye_region),
                                           ("mouth outline+fangs (cream)", ring, PROTOS["cream"], mouth_region),
                                           ("mouth inside (maroon)", m["maroon"], PROTOS["maroon"], mouth_region),
                                           ("tongue (coral+pink)", m["coral"] | m["pink"], PROTOS["coral"], mouth_region)):
        v, nr_, nd_ = iou(ref_mask, color, region)
        print(f"  {label}: IoU {v:.4f} (ref {nr_}, drawn {nd_})")

# ---------- ひげ（峰の形そのものを当てはめる: 左右を平均した中心線の 3 次ベジェと太さ）----------
print("== whiskers at the peak: centerline cubic (root -> tip, canvas units) and thickness, left/right averaged")
rights = sorted([c for c in comps if c[:, 1].mean() >= W / 2], key=lambda c: c[:, 0].min())
wh_end = 0.0146 * 0.33 / 2 * H   # 製品の端の半径（px）
for idx in range(3):
    sides = []
    for comp, mirror_x in ((lefts[idx], False), (rights[idx], True)):
        per = defaultdict(list)
        for y, x in comp:
            per[(W - 1 - x) if mirror_x else x].append(y)
        xs_side = sorted(per)
        sides.append({x: (np.mean(per[x]) + 0.5, len(per[x])) for x in xs_side})
    # 端は左右それぞれの端の平均（左右で長さが違うので、列の和ではなく端の位置を平均する）。中心線は両方にある列の平均。
    ends = []
    for which in (max, min):
        xs_end = [which(side) for side in sides]
        ends.append(np.array([np.mean([(x + 0.5) / W * A for x in xs_end]), np.mean([side[x][0] / H for side, x in zip(sides, xs_end)])]))
    root, tip = ends
    root[0] -= wh_end / H / A * A / A * A if False else wh_end / W * A   # 丸い端の半径分だけ内側（実寸）
    tip[0] += wh_end / W * A
    shared = sorted(set(sides[0]) & set(sides[1]))
    center = np.array([[(x + 0.5) / W * A, np.mean([side[x][0] for side in sides]) / H] for x in shared])
    extent = np.array([np.mean([side[x][1] for side in sides]) for x in shared]) / H
    inner = center[4:-4][::-1]   # 根元 → 先端の順（列は x 昇順なので反転）
    c1, c2, err = fit(inner, root, tip, ("free",), ("free",))
    sm = np.array([np.roll(center, s, 0) for s in range(-5, 6)]).mean(0)
    slope = np.gradient(sm[:, 1]) / np.maximum(np.gradient(sm[:, 0]), 1e-9)
    thick = extent * np.cos(np.arctan(slope))
    n = len(thick)
    bb = [[(lefts[idx][:, 1].min()) / W, (lefts[idx][:, 1].max() + 1) / W, lefts[idx][:, 0].min() / H, (lefts[idx][:, 0].max() + 1) / H],
          [1 - (rights[idx][:, 1].max() + 1) / W, 1 - rights[idx][:, 1].min() / W, rights[idx][:, 0].min() / H, (rights[idx][:, 0].max() + 1) / H]]
    avg = np.mean(bb, 0)
    print(f"  whisker {idx + 1}: root {fmt(cv(root))} c1 {fmt(cv(c1))} c2 {fmt(cv(c2))} tip {fmt(cv(tip))} rms {np.sqrt((err ** 2).mean()) * H:.2f} px;"
          f" thickness cvH max {thick.max():.4f}, root end {thick[int(0.95 * n)]:.4f} / tip end {thick[int(0.05 * n)]:.4f} (production 0.0146, end ratio 0.33)")
    print(f"    bbox left x {bb[0][0]:.4f}..{bb[0][1]:.4f} y {bb[0][2]:.4f}..{bb[0][3]:.4f} | right mirrored x {bb[1][0]:.4f}..{bb[1][1]:.4f} y {bb[1][2]:.4f}..{bb[1][3]:.4f}"
          f" | average x {avg[0]:.4f}..{avg[1]:.4f} y {avg[2]:.4f}..{avg[3]:.4f}")
    print(f"    swift: WhiskerSpec(root: {fmt(cv(root))}, control1: {fmt(cv(c1))}, control2: {fmt(cv(c2))}, tip: {fmt(cv(tip))}, thickness: {thick.max():.4f}),")
    # 左右別（右は鏡映して左の座標で）。下の 1 本は左右で長さが 0.02 違うので、峰では左右別の形を使う。
    for name, cols in (("left", sides[0]), ("right (mirrored)", sides[1])):
        xs = sorted(cols)
        r = np.array([(xs[-1] + 0.5) / W * A, cols[xs[-1]][0] / H]); r[0] -= wh_end / W * A
        t = np.array([(xs[0] + 0.5) / W * A, cols[xs[0]][0] / H]); t[0] += wh_end / W * A
        c = np.array([[(x + 0.5) / W * A, cols[x][0] / H] for x in xs])
        c1s, c2s, err_s = fit(c[4:-4][::-1], r, t, ("free",), ("free",))
        sm_s = np.array([np.roll(c, s, 0) for s in range(-5, 6)]).mean(0)
        slope_s = np.gradient(sm_s[:, 1]) / np.maximum(np.gradient(sm_s[:, 0]), 1e-9)
        thick_s = (np.array([cols[x][1] for x in xs]) / H) * np.cos(np.arctan(slope_s))
        print(f"    {name} swift: WhiskerSpec(root: {fmt(cv(r))}, control1: {fmt(cv(c1s))}, control2: {fmt(cv(c2s))}, tip: {fmt(cv(t))},"
              f" thickness: {thick_s.max():.4f}),  rms {np.sqrt((err_s ** 2).mean()) * H:.2f} px")
