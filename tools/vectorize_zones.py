#!/usr/bin/env python3
"""Bölge ızgarasını (zones.bin) vektör çokgenlere çevirir.

Uygulama bu çokgenleri MapKit'te keskin kenarlı, yarı saydam alanlar olarak çizer;
taranmış resmi harita her yakınlaşmada pikselleşirken vektör katman net kalır.
Çokgenler doğrudan uygulamanın konum sorgusunda kullandığı ızgaradan üretildiği için
ekranda görülen sınır ile uyarı veren sınır aynıdır.

Kullanım:
  python3 tools/vectorize_zones.py ios/AvHaritasi/MapData/istanbul_2026_2027.json

Çıktı: <ad>.vectors.json  {"classes": {"<id>": [[dış halka, delik, ...], ...]}}
Her halka düz [boylam, enlem, boylam, enlem, ...] listesidir (5 ondalık ≈ 1 m).
"""
import json
import os
import sys
import zlib

import cv2
import numpy as np

EPSILON_PX = 0.8    # Douglas-Peucker toleransı (~25 m)
MIN_AREA_PX = 12    # bundan küçük parçalar (≈ 1 ha) atılır


def chaikin(ring, iterations=1):
    """Köşeleri yumuşat (kapalı halka). Basılı haritadaki eğrilere daha yakın görünür."""
    pts = ring
    for _ in range(iterations):
        nxt = np.roll(pts, -1, axis=0)
        q = 0.75 * pts + 0.25 * nxt
        r = 0.25 * pts + 0.75 * nxt
        pts = np.empty((len(pts) * 2, 2))
        pts[0::2], pts[1::2] = q, r
    return pts


def main(meta_path):
    meta = json.load(open(meta_path))
    base = os.path.dirname(meta_path)
    z = meta["zones"]
    w, h = z["width"], z["height"]
    raw = zlib.decompress(open(os.path.join(base, z["file"]), "rb").read(), -15)
    grid = np.frombuffer(raw, np.uint8).reshape(h, w)

    H = np.array(z["lonLatToPixel"]).reshape(3, 3)
    Hinv = np.linalg.inv(H)

    def to_lonlat(px):
        # Kontur noktaları piksel merkezlerinde: +0.5
        p = np.column_stack([px[:, 0] + 0.5, px[:, 1] + 0.5, np.ones(len(px))]) @ Hinv.T
        return p[:, :2] / p[:, 2:3]

    out = {}
    total = 0
    for c in meta["classes"]:
        cid = c["id"]
        if cid == 0:
            continue
        mask = (grid == cid).astype(np.uint8)
        if not mask.any():
            continue
        contours, hier = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        if hier is None:
            continue
        hier = hier[0]
        polys = {}
        for i, cnt in enumerate(contours):
            if abs(cv2.contourArea(cnt)) < MIN_AREA_PX:
                continue
            approx = cv2.approxPolyDP(cnt, EPSILON_PX, True).reshape(-1, 2).astype(float)
            if len(approx) < 3:
                continue
            ring = to_lonlat(chaikin(approx))
            flat = [round(float(v), 5) for v in ring.ravel()]
            total += len(ring)
            parent = hier[i][3]
            if parent < 0:
                polys.setdefault(i, [None])[0] = flat
            else:
                polys.setdefault(parent, [None]).append(flat)
        out[str(cid)] = [rings for rings in polys.values() if rings[0] is not None]

    path = os.path.join(base, meta["name"] + ".vectors.json")
    with open(path, "w") as f:
        json.dump({"source": meta["name"], "classes": out}, f, separators=(",", ":"))
    print(f"{path}: {total} nokta, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1])
