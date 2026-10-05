#!/usr/bin/env python3
"""
GeoPDF avlak haritasındaki vektör katmanları ve avlak birimlerini çıkarır.

MAK kararındaki mesafe kuralları için (Madde 8/7: meskûn yerler, mesire yerleri
ve Karayolları Genel Müdürlüğü yollarına 300 m) haritadaki şu öğeler kullanılır:

  * Köy / ilçe / il merkezleri  (ESRIDefaultMarker sembolleri + en yakın ad)
  * Mesire yerleri              (turuncu sembol)
  * Karayolu ve Ekspres yol     (KGM yolu kabul edilir)
  * Asfalt yol                  (KGM yolu olabilir -> dikkat)

Ayrıca raster katmandaki avlak sınırları (pembe çizgiler) ve vektör il sınırıyla
haritayı avlak birimlerine böler, "ŞİLE D.A." gibi etiketlere göre adlandırır
(<ad>.units.bin + units listesi).

Kullanım:
  python3 tools/extract_features.py maps/34_istanbul_2024_2025.pdf \
      --name istanbul_2024_2025 --out ios/AvHaritasi/MapData
"""
import argparse
import json
import math
import re
import sys
import zlib

import numpy as np
import pymupdf
from scipy import ndimage
from skimage.segmentation import watershed

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from generate_assets import homography, apply_h, parse_geopdf, raster_only_page, render  # noqa: E402

MARKER_FONT = "ESRIDefaultMarker"
RED = 0xE60000
ORANGE = 0xE69800

# Lejantta: Karayolu siyah 1.01 pt, Asfalt siyah 0.72 pt, Ekspres yol siyah 1.44
# (haritada 1.58) üzerine kırmızı 1.15 pt.
ROAD_STYLES = {
    "kgm": [((0.0, 0.0, 0.0), 1.01), ((0.0, 0.0, 0.0), 1.58), ((1.0, 0.22, 0.22), 1.15)],
    "asfalt": [((0.0, 0.0, 0.0), 0.72)],
}


def line_text(line):
    """Satırı karakter kutularından yeniden kurar: ArcMap PDF'lerinde harf
    aralarına sahte boşluklar giriyor ("Kıyık Öy"); yalnızca gerçek boşlukları tut."""
    chars = [ch for s in line["spans"] for ch in s["chars"]]
    size = line["spans"][0]["size"]
    out, prev = "", None
    for ch in chars:
        if ch["c"] == " ":
            continue
        if prev is not None and ch["bbox"][0] - prev[2] > 0.22 * size:
            out += " "
        out += ch["c"]
        prev = ch["bbox"]
    return out.strip()


def title_tr(s):
    s = s.replace("I", "ı").replace("İ", "i").lower()
    return " ".join(w[:1].replace("i", "İ").replace("ı", "I").upper() + w[1:] for w in s.split(" "))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--name", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--unit-scale", type=float, default=2.5)
    a = ap.parse_args()

    doc = pymupdf.open(a.pdf)
    page = doc[0]
    bbox, gpts, lpts = parse_geopdf(doc, page)
    bx0, by0, bx1, by1 = bbox
    ph = page.rect.height
    pt = lambda u, v: (bx0 + u * (bx1 - bx0), ph - (by0 + v * (by1 - by0)))
    corners_pt = [pt(lpts[i], lpts[i + 1]) for i in range(0, 8, 2)]
    corners_ll = [(gpts[i + 1], gpts[i]) for i in range(0, 8, 2)]
    H_ll2pt = homography(corners_ll, corners_pt)
    H_pt2ll = np.linalg.inv(H_ll2pt)
    xs = [c[0] for c in corners_pt]; ys = [c[1] for c in corners_pt]
    clip = pymupdf.Rect(min(xs), min(ys), max(xs), max(ys))

    def ll(x, y):
        lon, lat = apply_h(H_pt2ll, x, y)
        return round(float(lat), 6), round(float(lon), 6)

    # Lejant ve bilgi kutuları (bunların içindeki semboller harita öğesi değildir)
    boxes = [d["rect"] for d in page.get_drawings()
             if d.get("fill") == (1.0, 1.0, 1.0) and d["rect"].width * d["rect"].height > 1500
             and d["rect"].width < clip.width * 0.6 and clip.intersects(d["rect"])]
    in_box = lambda x, y: any(r.contains(pymupdf.Point(x, y)) for r in boxes) or not clip.contains(pymupdf.Point(x, y))

    # --- Metinler: semboller ve etiketler -------------------------------------
    markers, labels, unit_labels = [], [], []
    for b in page.get_text("rawdict")["blocks"]:
        for l in b.get("lines", []):
            for s in l["spans"]:
                if s["font"] == MARKER_FONT:
                    for ch in s["chars"]:
                        x0, y0, x1, y1 = ch["bbox"]
                        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                        if in_box(cx, cy):
                            continue
                        if s["color"] == RED and ch["c"] == "!":
                            kind = "koy" if s["size"] < 6 else ("ilce" if s["size"] < 15 else "il")
                            markers.append((kind, cx, cy))
                        elif s["color"] == ORANGE:
                            markers.append(("mesire", cx, cy))
            t = line_text(l)
            x0, y0, x1, y1 = l["bbox"]
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            if in_box(cx, cy) or not t or l["spans"][0]["font"] == MARKER_FONT:
                continue
            if re.search(r"[DGÖO]\.\s?A\.?$", t):
                unit_labels.append((t, cx, cy))
            elif re.search(r"[a-zçğıöşü]", t) or l["spans"][0]["size"] > 9:
                labels.append((t, cx, cy, x0, y0, x1, y1))

    def nearest_label(x, y, maxd=25):
        best, bd = None, maxd
        for t, cx, cy, x0, y0, x1, y1 in labels:
            dx = max(x0 - x, 0, x - x1); dy = max(y0 - y, 0, y - y1)
            d = math.hypot(dx, dy)
            if d < bd:
                best, bd = t, d
        return best

    places = []
    for kind, x, y in markers:
        lat, lon = ll(x, y)
        name = nearest_label(x, y) if kind != "mesire" else None
        places.append(dict(kind=kind, name=title_tr(name) if name else None, lat=lat, lon=lon))
    print("Noktalar: " + ", ".join(f"{k}={sum(p['kind'] == k for p in places)}"
                                    for k in ("il", "ilce", "koy", "mesire")), file=sys.stderr)

    # --- Yollar ----------------------------------------------------------------
    roads = {k: [] for k in ROAD_STYLES}
    il_siniri = []
    for d in page.get_drawings():
        col = d.get("color"); w = d.get("width") or 0
        if col is None or d["type"] not in ("s", "fs"):
            continue
        col = tuple(round(c, 2) for c in col)
        if col == (0.0, 0.15, 0.45) and abs(w - 3.02) < 0.05:
            il_siniri.append(d)
            continue
        for kind, styles in ROAD_STYLES.items():
            if any(col == c and abs(w - sw) < 0.03 for c, sw in styles):
                line = []
                for it in d["items"]:
                    if it[0] == "l":
                        p0, p1 = it[1], it[2]
                    elif it[0] == "c":
                        p0, p1 = it[1], it[4]
                    else:
                        continue
                    if in_box(p0.x, p0.y) and in_box(p1.x, p1.y):
                        continue
                    if line and math.dist(line[-1], (p0.x, p0.y)) < 0.05:
                        line.append((p1.x, p1.y))
                    else:
                        if len(line) > 1:
                            roads[kind].append(line)
                        line = [(p0.x, p0.y), (p1.x, p1.y)]
                if len(line) > 1:
                    roads[kind].append(line)
                break

    def simplify(line, tol=0.15):
        # Douglas-Peucker (pt cinsinden; 0.15 pt ≈ 20 m)
        if len(line) < 3:
            return line
        (x0, y0), (x1, y1) = line[0], line[-1]
        dx, dy = x1 - x0, y1 - y0
        L = math.hypot(dx, dy) or 1e-9
        dmax, idx = -1, 0
        for i in range(1, len(line) - 1):
            px, py = line[i]
            dd = abs(dy * px - dx * py + x1 * y0 - y1 * x0) / L
            if dd > dmax:
                dmax, idx = dd, i
        if dmax > tol:
            return simplify(line[:idx + 1], tol)[:-1] + simplify(line[idx:], tol)
        return [line[0], line[-1]]

    road_out = {}
    for kind, lines in roads.items():
        out = []
        for line in lines:
            s = simplify(line)
            out.append([list(ll(x, y)) for x, y in s])
        road_out[kind] = out
        print(f"Yol {kind}: {len(out)} çizgi, {sum(len(l) - 1 for l in out)} parça", file=sys.stderr)

    # --- Avlak birimleri ----------------------------------------------------------
    us = a.unit_scale
    rdoc, rpage = raster_only_page(a.pdf)
    img = render(rpage, clip, us).astype(np.int32)
    magenta = ((img - np.array([252, 0, 196])) ** 2).sum(axis=2) < 40 ** 2
    white = img.min(axis=2) >= 245
    barrier = magenta.copy()
    # Vektör il sınırını engel olarak çiz
    for d in il_siniri:
        for it in d["items"]:
            if it[0] != "l":
                continue
            p0, p1 = it[1], it[2]
            n = int(max(abs(p1.x - p0.x), abs(p1.y - p0.y)) * us * 2) + 2
            xs_ = np.linspace((p0.x - clip.x0) * us, (p1.x - clip.x0) * us, n).astype(int)
            ys_ = np.linspace((p0.y - clip.y0) * us, (p1.y - clip.y0) * us, n).astype(int)
            ok = (xs_ >= 0) & (ys_ >= 0) & (xs_ < img.shape[1]) & (ys_ < img.shape[0])
            barrier[ys_[ok], xs_[ok]] = True
    # İl sınırı kesik çizgi: boşlukları kapat
    barrier = ndimage.binary_dilation(barrier, iterations=2)
    land = ~white & ~barrier
    # Her etiketten başlayıp kara alanında yayılan bölütleme (watershed): sınır
    # çizgileri kesintili olsa da birimler en dar yerlerden / çizgilerden ayrılır.
    def unit_name(t):
        t = re.sub(r"\s*([DGÖO])\.\s?A\.?$", r" \1.A.", t)
        head, tail = t.rsplit(" ", 1)
        return head.replace(" ", "") + " " + tail
    markers_img = np.zeros(land.shape, np.int32)
    names = []
    for t, cx, cy in unit_labels:
        nm = unit_name(t)
        if nm not in names:
            names.append(nm)
        px, py = int((cx - clip.x0) * us), int((cy - clip.y0) * us)
        sl = (slice(max(0, py - 4), py + 5), slice(max(0, px - 4), px + 5))
        seed = land[sl]
        markers_img[sl][seed] = names.index(nm) + 1
    elevation = -ndimage.distance_transform_edt(land)
    grid = watershed(elevation, markers_img, mask=~white).astype(np.uint8)
    name_id = {nm: i + 1 for i, nm in enumerate(names)}
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(f"{a.out}/{a.name}.units.bin", "wb") as fh:
        fh.write(comp.compress(grid.astype(np.uint8).tobytes()) + comp.flush())
    H_units = homography(corners_ll, [((x - clip.x0) * us, (y - clip.y0) * us) for x, y in corners_pt])
    print(f"Avlak birimleri: {len(names)} -> {names}", file=sys.stderr)

    out = dict(
        name=a.name,
        places=places,
        roads=road_out,
        units=dict(file=f"{a.name}.units.bin", width=int(grid.shape[1]), height=int(grid.shape[0]),
                   lonLatToPixel=[float(v) for v in H_units.flatten()],
                   names=[dict(id=name_id[nm], label=nm) for nm in names]),
    )
    with open(f"{a.out}/{a.name}.features.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, separators=(",", ":"))
    print("Tamam.", file=sys.stderr)


if __name__ == "__main__":
    main()
