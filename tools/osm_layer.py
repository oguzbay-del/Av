#!/usr/bin/env python3
"""
MAK kararındaki mesafe kuralları için OpenStreetMap'ten "hassas yer" katmanı üretir.

Madde 8/7: meskûn yerler, mesire/piknik yerleri ve göletlere 300 m; askeri alanlar,
cezaevleri, eğitim, sağlık, spor tesisleri, kamplar ve huzurevlerine 500 m içinde
avlanmak yasaktır. Bunların çoğu avlak haritasında yok; OSM'den alınır.

Çıktı, avlak haritasının bölge ızgarasıyla aynı ızgarada (aynı piksel/koordinat
dönüşümü) bir sınıf ızgarasıdır:
  ios/AvHaritasi/MapData/istanbul_osm.bin   (ham DEFLATE, bayt başına sınıf)
  ios/AvHaritasi/MapData/istanbul_osm.json  (sınıflar, kural mesafeleri, kaynak)

Kullanım:
  python3 tools/osm_layer.py --fetch          # Overpass'tan indir (internet gerekir)
  python3 tools/osm_layer.py                  # data/osm_cache.json'dan yeniden üret

Veri © OpenStreetMap katkıcıları, ODbL.
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import zlib

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPDATA = os.path.join(ROOT, "ios", "AvHaritasi", "MapData")
CACHE = os.path.join(ROOT, "data", "osm_cache.json")
ZONE_META = os.path.join(MAPDATA, "istanbul_2026_2027.json")
OVERPASS = ["https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass.private.coffee/api/interpreter"]

# Çizim sırası = öncelik (sonraki öncekinin üstüne yazar). meters: yasak mesafe.
CLASSES = [
    dict(id=1, key="yerlesim", name="Yerleşim alanı", meters=300, rule="Madde 8/7 (meskûn yerler)",
         level="yasak", query=['nwr["landuse"="residential"]', 'nwr["place"~"^(village|hamlet|neighbourhood|suburb|town)$"]']),
    dict(id=2, key="gol", name="Gölet / su birikintisi", meters=300, rule="Madde 8/1-e, 8/7 (göletler)",
         level="dikkat", query=['nwr["natural"="water"]["water"~"^(pond|reservoir|basin|lake)$"]']),
    dict(id=3, key="mesire", name="Mesire / piknik yeri", meters=300, rule="Madde 8/1-ç, 8/7",
         level="yasak", query=['nwr["tourism"="picnic_site"]', 'nwr["leisure"="picnic_site"]']),
    dict(id=4, key="spor", name="Spor tesisi / kamp", meters=500, rule="Madde 8/6, 8/7",
         level="yasak", query=['nwr["leisure"~"^(sports_centre|stadium)$"]', 'nwr["tourism"="camp_site"]']),
    dict(id=5, key="egitim", name="Eğitim tesisi", meters=500, rule="Madde 8/6, 8/7",
         level="yasak", query=['nwr["amenity"~"^(school|kindergarten|college|university)$"]']),
    dict(id=6, key="saglik", name="Sağlık tesisi / huzurevi", meters=500, rule="Madde 8/6, 8/7",
         level="yasak", query=['nwr["amenity"~"^(hospital|clinic|nursing_home)$"]',
                               'nwr["social_facility"="nursing_home"]']),
    dict(id=7, key="cezaevi", name="Cezaevi", meters=500, rule="Madde 8/6, 8/7",
         level="yasak", query=['nwr["amenity"="prison"]']),
    dict(id=8, key="askeri", name="Askeri alan / tesis", meters=500, rule="Madde 8/3-4, 8/7",
         level="yasak", query=['nwr["landuse"="military"]', 'nwr["military"]']),
]
BBOX = (40.80, 27.95, 41.62, 29.98)   # güney, batı, kuzey, doğu (İstanbul + çevresi)


def overpass(query):
    body = urllib.parse.urlencode({"data": query}).encode()
    last = None
    for attempt in range(2):
        for url in OVERPASS:
            try:
                req = urllib.request.Request(url, data=body, headers={"User-Agent": "AvHaritasi/1.0 (github.com/oguzbay-del/Av)"})
                with urllib.request.urlopen(req, timeout=150) as r:
                    return json.load(r)
            except Exception as e:  # noqa: BLE001 — ağ hataları: yansıya geç / yeniden dene
                last = e
                print(f"    {url}: {e}", file=sys.stderr, flush=True)
        time.sleep(20)
    raise SystemExit(f"Overpass'a ulaşılamadı: {last}")


def tiles(nx=4, ny=2):
    """Büyük sorguları küçük karolara böl (Overpass zaman aşımlarını önler)."""
    s, w, n, e = BBOX
    for j in range(ny):
        for i in range(nx):
            yield (s + (n - s) * j / ny, w + (e - w) * i / nx,
                   s + (n - s) * (j + 1) / ny, w + (e - w) * (i + 1) / nx)


def fetch():
    out = {"bbox": BBOX, "fetched": time.strftime("%Y-%m-%d"), "classes": {}}
    for c in CLASSES:
        print(f"{c['name']} indiriliyor...", file=sys.stderr, flush=True)
        seen, els = set(), []
        for (s, w, n, e) in tiles():
            parts = "".join(f"{q}({s:.4f},{w:.4f},{n:.4f},{e:.4f});" for q in c["query"])
            data = overpass(f"[out:json][timeout:120];({parts});out geom qt;")
            for el in data.get("elements", []):
                k = (el.get("type"), el.get("id"))
                if k not in seen:
                    seen.add(k)
                    els.append(el)
            time.sleep(2)
        out["classes"][c["key"]] = els
        print(f"  {len(els)} öğe", file=sys.stderr, flush=True)
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, separators=(",", ":"))
    return out


def element_shapes(el):
    """Bir OSM öğesinden çizilecek şekiller: ('point', [(lat, lon)]) ya da ('poly', [...])."""
    t = el.get("type")
    if t == "node":
        return [("point", [(el["lat"], el["lon"])])]
    if t == "way" and el.get("geometry"):
        pts = [(g["lat"], g["lon"]) for g in el["geometry"]]
        closed = len(pts) > 3 and pts[0] == pts[-1]
        return [("poly" if closed else "line", pts)]
    if t == "relation":
        shapes = []
        for m in el.get("members", []):
            if m.get("role") in ("outer", "") and m.get("geometry"):
                pts = [(g["lat"], g["lon"]) for g in m["geometry"]]
                shapes.append(("poly" if len(pts) > 3 and pts[0] == pts[-1] else "line", pts))
        if not shapes and "center" in el:
            shapes.append(("point", [(el["center"]["lat"], el["center"]["lon"])]))
        return shapes
    return []


def build(cache):
    meta = json.load(open(ZONE_META, encoding="utf-8"))
    W, H = meta["zones"]["width"], meta["zones"]["height"]
    h = meta["zones"]["lonLatToPixel"]

    def px(lat, lon):
        w = h[6] * lon + h[7] * lat + h[8]
        return ((h[0] * lon + h[1] * lat + h[2]) / w, (h[3] * lon + h[4] * lat + h[5]) / w)

    img = Image.new("L", (W, H), 0)
    dr = ImageDraw.Draw(img)
    counts = {}
    for c in CLASSES:
        els = cache["classes"].get(c["key"], [])
        n = 0
        for el in els:
            tags = el.get("tags", {})
            # Yer adları: yalnızca köy/mahalle noktası olarak kullan (geniş "place" alanları hariç)
            if c["key"] == "yerlesim" and "place" in tags and el.get("type") != "node":
                continue
            for kind, pts in element_shapes(el):
                xy = [px(la, lo) for la, lo in pts]
                if kind == "poly" and len(xy) >= 3:
                    dr.polygon(xy, fill=c["id"])
                elif kind == "line" and len(xy) >= 2:
                    dr.line(xy, fill=c["id"], width=1)
                else:
                    x, y = xy[0]
                    dr.point((x, y), fill=c["id"])
                n += 1
        counts[c["key"]] = n
    grid = np.array(img, dtype=np.uint8)
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(os.path.join(MAPDATA, "istanbul_osm.bin"), "wb") as fh:
        fh.write(comp.compress(grid.tobytes()) + comp.flush())
    out = dict(
        source="© OpenStreetMap katkıcıları (ODbL), Overpass API",
        fetched=cache.get("fetched"),
        file="istanbul_osm.bin", width=W, height=H, lonLatToPixel=h,
        classes=[{k: v for k, v in c.items() if k != "query"} for c in CLASSES],
    )
    with open(os.path.join(MAPDATA, "istanbul_osm.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)
    for c in CLASSES:
        cells = int((grid == c["id"]).sum())
        print(f"  {c['name']:28s} {counts[c['key']]:6d} şekil, {cells:8d} hücre", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true", help="Overpass'tan yeniden indir")
    a = ap.parse_args()
    cache = fetch() if a.fetch else json.load(open(CACHE, encoding="utf-8"))
    build(cache)


if __name__ == "__main__":
    main()
