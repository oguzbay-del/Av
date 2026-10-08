#!/usr/bin/env python3
"""Avlak birimi ızgarasını (features.json → units.bin) vektör çokgenlere çevirir.

Uygulama izin belgesindeki ya da elle seçilen avlağı haritada bu çokgenlerle vurgular ve
yol tarifi için avlağın içinden bir hedef nokta seçer.

  python3 tools/vectorize_units.py ios/AvHaritasi/MapData/istanbul_2024_2025.features.json

Çıktı: <ad>.units.vectors.json
  {"units": {"ŞİLE D.A.": {"label": [boylam, enlem], "polygons": [[dış halka, delik...], ...]}}}
"""
import json
import os
import sys
import zlib

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vectorize_zones import EPSILON_PX, chaikin  # noqa: E402

MIN_AREA_PX = 40


def main(path):
    feat = json.load(open(path, encoding="utf-8"))
    u = feat["units"]
    base = os.path.dirname(path)
    w, h = u["width"], u["height"]
    grid = np.frombuffer(zlib.decompress(open(os.path.join(base, u["file"]), "rb").read(), -15), np.uint8).reshape(h, w)
    Hinv = np.linalg.inv(np.array(u["lonLatToPixel"]).reshape(3, 3))

    def to_lonlat(px):
        p = np.column_stack([px[:, 0] + 0.5, px[:, 1] + 0.5, np.ones(len(px))]) @ Hinv.T
        return p[:, :2] / p[:, 2:3]

    out = {}
    for n in u["names"]:
        mask = (grid == n["id"]).astype(np.uint8)
        if not mask.any():
            continue
        contours, hier = cv2.findContours(mask, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
        hier = hier[0]
        polys = {}
        for i, cnt in enumerate(contours):
            if abs(cv2.contourArea(cnt)) < MIN_AREA_PX:
                continue
            approx = cv2.approxPolyDP(cnt, EPSILON_PX, True).reshape(-1, 2).astype(float)
            if len(approx) < 3:
                continue
            flat = [round(float(v), 5) for v in to_lonlat(chaikin(approx)).ravel()]
            parent = hier[i][3]
            if parent < 0:
                polys.setdefault(i, [None])[0] = flat
            else:
                polys.setdefault(parent, [None]).append(flat)
        # Etiket noktası: avlağın en "iç" noktası (kenara en uzak hücre)
        dist = cv2.distanceTransform(np.pad(mask, 1), cv2.DIST_L2, 5)[1:-1, 1:-1]
        y, x = np.unravel_index(int(np.argmax(dist)), dist.shape)
        lon, lat = to_lonlat(np.array([[x, y]], float))[0]
        out[n["label"]] = {"label": [round(float(lon), 5), round(float(lat), 5)],
                           "polygons": [r for r in polys.values() if r[0] is not None]}
    name = os.path.basename(path).replace(".features.json", "")
    dst = os.path.join(base, name + ".units.vectors.json")
    json.dump({"source": name, "units": out}, open(dst, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"{dst}: {len(out)} avlak, {os.path.getsize(dst) // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1])
