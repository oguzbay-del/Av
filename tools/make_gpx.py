#!/usr/bin/env python3
"""Simülatör ve saha ön testleri için yürüyüş GPX izleri üretir.

Çıktı: ios/TestData/GPX/  (uygulama paketine girmez)
  NN_senaryo.gpx  -> Xcode (Debug › Simulate Location, şema Run › Options)
  NN_senaryo.txt  -> `xcrun simctl location booted start --speed=1.3 - < NN_senaryo.txt`

Koordinatlar elle değil, uygulamanın kendi verisinden hesaplanır:
  * istanbul_2026_2027.vectors.json   (bölge çokgenleri; sınır geçişi / mesafe)
  * istanbul_2026_2027.zones.bin      (uygulamanın kullandığı bölge rasterı)
  * istanbul_2024_2025.features.json  (köy/ilçe/mesire noktaları, KGM ve asfalt yollar)
  * istanbul_osm.bin                  (OSM yerleşim, okul, askeri alan vb.)
  * mak_2026_2027.json                (özel çokgenler: Adalar, Kızılcaköy YHYS)

Her senaryo için Assessment.placeChecks mantığı (seviye: güvenli / dikkat / tehlike)
Python'da taklit edilir; böylece "hangi saniyede hangi uyarı" beklenir, raporlanır.
Bu taklit yaklaşıktır (uygulama değişirse sonuçlar kayabilir), asıl doğrulama
simülatörde ve sahada yapılır.

Kullanım:  python3 tools/make_gpx.py [--out DIR] [--seed N] [--quiet]
Bağımlılık: yalnızca standart kütüphane. shapely kuruluysa ek çapraz doğrulama yapılır.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import random
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPDATA = os.path.join(ROOT, "ios", "AvHaritasi", "MapData")
DEFAULT_OUT = os.path.join(ROOT, "ios", "TestData", "GPX")

START_TIME = dt.datetime(2026, 10, 7, 6, 30, 0, tzinfo=dt.timezone.utc)
SPEED = 1.3          # m/s yürüyüş
DT = 2.0             # s, nokta aralığı
ACC = 5.0            # simülatörün bildirdiği yatay doğruluk (m)
M_LAT = 110_540.0    # uygulamadaki LocalProjection sabitleri
M_LON0 = 111_320.0

FORBIDDEN = {3, 4, 5}
LEVELS = {0: "bilinmiyor", 1: "güvenli", 2: "dikkat", 3: "TEHLİKE"}

try:  # isteğe bağlı çapraz doğrulama
    import shapely.geometry as SG  # type: ignore
except Exception:  # pragma: no cover
    SG = None


# --------------------------------------------------------------------------- geometri

def mlon(lat: float) -> float:
    return M_LON0 * math.cos(math.radians(lat))


def offset(lat: float, lon: float, east: float, north: float) -> tuple[float, float]:
    return lat + north / M_LAT, lon + east / mlon(lat)


def vec(a, b):
    """a -> b vektörü (doğu, kuzey) metre; a ve b (lat, lon)."""
    return (b[1] - a[1]) * mlon(a[0]), (b[0] - a[0]) * M_LAT


def dist(a, b) -> float:
    e, n = vec(a, b)
    return math.hypot(e, n)


def seg_dist(p, a, b) -> tuple[float, tuple[float, float]]:
    """p noktasının [a,b] parçasına uzaklığı ve en yakın nokta (lat, lon)."""
    k = mlon(p[0])
    ax, ay = (a[1] - p[1]) * k, (a[0] - p[0]) * M_LAT
    bx, by = (b[1] - p[1]) * k, (b[0] - p[0]) * M_LAT
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / l2))
    qx, qy = ax + t * dx, ay + t * dy
    return math.hypot(qx, qy), (p[0] + qy / M_LAT, p[1] + qx / k)


def lerp(a, b, t):
    return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t


def bearing_pt(c, brg_deg: float, d: float):
    r = math.radians(brg_deg)
    return offset(c[0], c[1], d * math.sin(r), d * math.cos(r))


def unit(e, n):
    l = math.hypot(e, n) or 1.0
    return e / l, n / l


# --------------------------------------------------------------------------- veri

class Polygon:
    """Halkalar (lat, lon) listeleri; ilki dış halka, diğerleri delik."""

    def __init__(self, cls: int, rings):
        self.cls = cls
        self.rings = rings
        lats = [p[0] for p in rings[0]]
        lons = [p[1] for p in rings[0]]
        self.bbox = (min(lats), max(lats), min(lons), max(lons))

    def contains(self, p) -> bool:
        la, lo = p
        if not (self.bbox[0] <= la <= self.bbox[1] and self.bbox[2] <= lo <= self.bbox[3]):
            return False
        inside = False
        for ring in self.rings:
            j = len(ring) - 1
            for i in range(len(ring)):
                yi, xi = ring[i]
                yj, xj = ring[j]
                if (yi > la) != (yj > la) and lo < (xj - xi) * (la - yi) / (yj - yi) + xi:
                    inside = not inside
                j = i
        return inside

    def near_bbox(self, p, meters: float) -> bool:
        dla = meters / M_LAT
        dlo = meters / mlon(p[0])
        return (self.bbox[0] - dla <= p[0] <= self.bbox[1] + dla
                and self.bbox[2] - dlo <= p[1] <= self.bbox[3] + dlo)

    def boundary(self, p):
        best = (math.inf, None)
        for ring in self.rings:
            for i in range(len(ring)):
                d, q = seg_dist(p, ring[i - 1], ring[i])
                if d < best[0]:
                    best = (d, q)
        return best


class Data:
    def __init__(self):
        meta = json.load(open(os.path.join(MAPDATA, "istanbul_2026_2027.json")))
        self.classes = {c["id"]: c for c in meta["classes"]}
        vec_json = json.load(open(os.path.join(MAPDATA, "istanbul_2026_2027.vectors.json")))
        self.polys: list[Polygon] = []
        for cid, plist in vec_json["classes"].items():
            for rings in plist:
                rr = [[(r[i + 1], r[i]) for i in range(0, len(r), 2)] for r in rings]
                self.polys.append(Polygon(int(cid), rr))
        z = meta["zones"]
        self.zgrid, self.zw, self.zh, self.zH = self._raster(z["file"], z["width"], z["height"], z["lonLatToPixel"])
        osm = json.load(open(os.path.join(MAPDATA, "istanbul_osm.json")))
        self.osm_classes = osm["classes"]
        self.ogrid, self.ow, self.oh, self.oH = self._raster(osm["file"], osm["width"], osm["height"], osm["lonLatToPixel"])
        feat = json.load(open(os.path.join(MAPDATA, "istanbul_2024_2025.features.json")))
        self.places = feat["places"]
        self.roads = {k: [[tuple(p) for p in line] for line in v] for k, v in feat["roads"].items()}
        self.road_segs = {}
        for k, lines in self.roads.items():
            segs = []
            for line in lines:
                for a, b in zip(line, line[1:]):
                    segs.append((a, b, min(a[0], b[0]), max(a[0], b[0]), min(a[1], b[1]), max(a[1], b[1])))
            self.road_segs[k] = segs
        regs = json.load(open(os.path.join(MAPDATA, "mak_2026_2027.json")))
        self.overrides = []
        for o in regs.get("overrides", []):
            poly = o["polygon"]
            if isinstance(poly, str):
                poly = json.loads(poly)
            self.overrides.append((o, [tuple(p) for p in poly]))
        self.rules = {r["id"]: r["meters"] for r in regs.get("distanceRules", [])}

    @staticmethod
    def _raster(fname, w, h, H):
        raw = open(os.path.join(MAPDATA, fname), "rb").read()
        try:
            grid = zlib.decompress(raw, -15)       # Apple .zlib = ham DEFLATE
        except zlib.error:
            grid = zlib.decompress(raw)
        assert len(grid) == w * h, fname
        return grid, w, h, H

    # --- vektör sorguları
    def vclass(self, p) -> int:
        """Vektör çokgenlerine göre sınıf (çakışmada yasak sınıflar önce)."""
        found = [poly.cls for poly in self.polys if poly.contains(p)]
        for c in (4, 5, 3, 6, 1, 2):
            if c in found:
                return c
        return 0

    def vdist(self, p, classes, within=5000.0):
        """classes sınıfındaki çokgenlerin sınırına en kısa uzaklık ve en yakın nokta."""
        best = (math.inf, None, None)
        for poly in self.polys:
            if poly.cls in classes and poly.near_bbox(p, within):
                d, q = poly.boundary(p)
                if d < best[0]:
                    best = (d, q, poly)
        return best

    # --- raster sorguları (HuntingMap.zone / nearest, OSMLayer.nearestPerClass)
    @staticmethod
    def _pix(H, lat, lon):
        w = H[6] * lon + H[7] * lat + H[8]
        return (H[0] * lon + H[1] * lat + H[2]) / w, (H[3] * lon + H[4] * lat + H[5]) / w

    def zone(self, p) -> int | None:
        x, y = self._pix(self.zH, *p)
        ix, iy = int(math.floor(x)), int(math.floor(y))
        if not (0 <= ix < self.zw and 0 <= iy < self.zh):
            return None
        return self.zgrid[iy * self.zw + ix]

    def _nearest(self, grid, w, h, H, p, radius, match, pad=0.0):
        lat, lon = p
        x0, y0 = self._pix(H, lat, lon)
        d = 0.001
        xl, yl = self._pix(H, lat, lon + d)
        xa, ya = self._pix(H, lat + d, lon)
        a, b = (xl - x0) / d, (xa - x0) / d
        c, dd = (yl - y0) / d, (ya - y0) / d
        det = a * dd - b * c
        k = mlon(lat)
        rlo, rla = radius / k, radius / M_LAT
        rx = int(math.ceil(abs(a) * rlo + abs(b) * rla)) + 1
        ry = int(math.ceil(abs(c) * rlo + abs(dd) * rla)) + 1
        cx, cy = int(math.floor(x0)), int(math.floor(y0))
        best: dict[int, float] = {}
        for iy in range(max(0, cy - ry), min(h - 1, cy + ry) + 1):
            row = iy * w
            dy = iy + 0.5 - y0
            seg = grid[row + max(0, cx - rx): row + min(w - 1, cx + rx) + 1]
            for j, v in enumerate(seg):
                if v not in match:
                    continue
                ix = max(0, cx - rx) + j
                dx = ix + 0.5 - x0
                dlo = (dd * dx - b * dy) / det
                dla = (-c * dx + a * dy) / det
                dist_ = max(0.0, math.hypot(dlo * k, dla * M_LAT) - pad)
                if dist_ <= radius and dist_ < best.get(v, math.inf):
                    best[v] = dist_
        return best

    def zone_nearest(self, p, radius, classes):
        r = self._nearest(self.zgrid, self.zw, self.zh, self.zH, p, radius, set(classes))
        return min(r.values()) if r else None

    def osm_nearest(self, p, radius):
        return self._nearest(self.ogrid, self.ow, self.oh, self.oH, p, radius,
                             {c["id"] for c in self.osm_classes}, pad=15.0)

    # --- noktalar / yollar (MapFeatures)
    def nearest_place(self, p, kinds, radius):
        best = None
        for pl in self.places:
            if pl["kind"] not in kinds:
                continue
            d = dist(p, (pl["lat"], pl["lon"]))
            if d <= radius and (best is None or d < best[1]):
                best = (pl, d)
        return best

    def nearest_road(self, p, kind, radius):
        dla, dlo = radius / M_LAT, radius / mlon(p[0])
        best = math.inf
        for a, b, la0, la1, lo0, lo1 in self.road_segs.get(kind, []):
            if la0 - dla <= p[0] <= la1 + dla and lo0 - dlo <= p[1] <= lo1 + dlo:
                best = min(best, seg_dist(p, a, b)[0])
        return best if best <= radius else None


# --------------------------------------------------------------------------- uygulama taklidi

def contains_latlon(poly, p):
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        yi, xi = poly[i]
        yj, xj = poly[j]
        if (yi > p[0]) != (yj > p[0]) and p[1] < (xj - xi) * (p[0] - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def evaluate(D: Data, p, acc=ACC, warning_buffer=300.0):
    """Assessment.placeChecks taklidi. Dönüş: [(id, seviye, açıklama)]."""
    out = []
    z = D.zone(p)
    if z is None:
        return [("kapsam", 0, "harita dışı")]
    zc = D.classes.get(z, D.classes[0])
    st, key = zc["status"], zc["key"]
    out.append(("alan", {"yasak": 3, "dikkat": 2, "disarida": 2, "izinli": 1}[st], zc["name"]))
    for o, poly in D.overrides:
        lvl = 3 if o["status"] == "yasak" else 2
        if contains_latlon(poly, p):
            out.append(("ov-" + o["id"], lvl, o["name"]))
        else:
            dmin = min(seg_dist(p, poly[i - 1], poly[i])[0] for i in range(len(poly)))
            if o.get("buffer", 0) > 0 and dmin - acc <= o["buffer"]:
                out.append(("ov-" + o["id"], 3, f"{o['name']} {dmin:.0f} m"))
            elif dmin - acc <= warning_buffer:
                out.append(("ov-" + o["id"], 2, f"{o['name']} {dmin:.0f} m"))
    if key not in ("korunan_alan", "yaban_hayvani_yerlestirme"):
        m = D.rules.get("korunan", 300)
        d = D.zone_nearest(p, m + acc, (3, 5))
        if d is not None:
            out.append(("korunan", 3, f"korunan alan/YHYS {d:.0f} m"))
    if key != "ava_yasak":
        d = D.zone_nearest(p, warning_buffer + acc, (4,))
        if d is not None:
            out.append(("yasak-yakin", 2, f"ava yasak alana {d:.0f} m"))
    m = D.rules.get("meskun", 300)
    r = D.nearest_place(p, {"koy"}, m + 500 + acc)
    if r:
        out.append(("meskun", 3 if r[1] - acc <= m else 2, f"{r[0]['name'] or 'köy'} {r[1]:.0f} m"))
    r = D.nearest_place(p, {"ilce", "il"}, m + 1500 + acc)
    if r:
        out.append(("meskun-ilce", 3 if r[1] - acc <= m else 2, f"{r[0]['name']} {r[1]:.0f} m"))
    mm = D.rules.get("mesire", 300)
    r = D.nearest_place(p, {"mesire"}, mm + 200 + acc)
    if r:
        out.append(("mesire", 3 if r[1] - acc <= mm else 2, f"mesire {r[1]:.0f} m"))
    rm = D.rules.get("kgm", 300)
    d = D.nearest_road(p, "kgm", rm + acc)
    if d is not None:
        out.append(("kgm", 3, f"KGM yolu {d:.0f} m"))
    else:
        d = D.nearest_road(p, "asfalt", rm + acc)
        if d is not None:
            out.append(("asfalt", 2, f"asfalt yol {d:.0f} m"))
    maxm = max(c["meters"] for c in D.osm_classes)
    near = D.osm_nearest(p, maxm + acc)
    for c in D.osm_classes:
        d = near.get(c["id"])
        if d is not None and d - acc <= c["meters"]:
            out.append(("osm-" + c["key"], 3 if c["level"] == "yasak" else 2, f"OSM {c['name']} {d:.0f} m"))
    if acc > max(50, warning_buffer / 2):
        out.append(("gps", 2, "GPS doğruluğu düşük"))
    return out


def level_of(checks):
    return max((c[1] for c in checks), default=0)


def ids_ok(D, pts, allowed: set[str], required: set[str] = frozenset(), max_level=None):
    """Tüm noktalarda yalnızca izinli kural kimlikleri çıksın (alan hariç seviye kontrolü)."""
    for p in pts:
        ch = evaluate(D, p)
        ids = {c[0] for c in ch}
        if not ids <= allowed | {"alan"}:
            return False
        if not required <= ids:
            return False
        if max_level is not None and level_of(ch) > max_level:
            return False
    return True


def sample_line(a, b, step=50.0):
    n = max(1, int(dist(a, b) / step))
    return [lerp(a, b, i / n) for i in range(n + 1)]


# --------------------------------------------------------------------------- iz üretimi

class Track:
    """Zaman damgalı nokta dizisi (t saniye, lat, lon). Gerçekçi küçük GPS gürültüsü eklenir."""

    def __init__(self, rng: random.Random, start, noise=1.5):
        self.rng = rng
        self.t = 0.0
        self.pos = start
        self.pts: list[tuple[float, float, float]] = []
        self.noise = noise
        self.ne = self.nn = 0.0
        self.events: list[tuple[float, str]] = []
        self._emit()

    def _jitter(self, sigma, clamp=None):
        # AR(1) gürültü: ardışık ölçümler arası bağıntılı, gerçek GPS gibi
        self.ne = 0.8 * self.ne + self.rng.gauss(0, sigma * 0.6)
        self.nn = 0.8 * self.nn + self.rng.gauss(0, sigma * 0.6)
        if clamp is not None:
            l = math.hypot(self.ne, self.nn)
            if l > clamp:
                self.ne, self.nn = self.ne * clamp / l, self.nn * clamp / l
        return self.ne, self.nn

    def _emit(self, sigma=None, clamp=None):
        e, n = self._jitter(self.noise if sigma is None else sigma, clamp)
        la, lo = offset(self.pos[0], self.pos[1], e, n)
        self.pts.append((self.t, la, lo))

    def walk_to(self, target, speed=SPEED, emit=True):
        a = self.pos
        d = dist(a, target)
        done = 0.0
        while done < d - 1e-6:
            # hız ±%6 oynar (adım uzunluğu 2,4–2,8 m)
            done = min(d, done + speed * DT * (1 + self.rng.uniform(-0.06, 0.06)))
            self.t += DT
            self.pos = lerp(a, target, done / d)
            if emit:
                self._emit()
        return self

    def walk_path(self, path, speed=SPEED):
        for p in path:
            self.walk_to(p, speed)
        return self

    def stand(self, seconds, jitter=5.0):
        for _ in range(int(seconds / DT)):
            self.t += DT
            self._emit(sigma=jitter * 0.7, clamp=jitter)
        self.ne = self.nn = 0.0
        return self

    def gap_walk_to(self, target, speed=SPEED):
        """Yürümeye devam eder ama nokta kaydetmez (GPS kesintisi)."""
        t0 = self.t
        self.walk_to(target, speed, emit=False)
        self.events.append((t0, f"GPS kesintisi başlıyor ({self.t - t0:.0f} s)"))
        self._emit()
        return self

    def mark(self, text):
        self.events.append((self.t, text))
        return self


def iso(t: float) -> str:
    return (START_TIME + dt.timedelta(seconds=t)).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_gpx(path, name, desc, pts):
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<gpx version="1.1" creator="Av Haritasi tools/make_gpx.py" xmlns="http://www.topografix.com/GPX/1/1">',
             f"  <metadata><name>{name}</name><desc>{desc}</desc><time>{iso(0)}</time></metadata>"]
    for t, la, lo in pts:
        lines.append(f'  <wpt lat="{la:.6f}" lon="{lo:.6f}"><time>{iso(t)}</time></wpt>')
    lines.append("</gpx>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_txt(path, pts):
    with open(path, "w", encoding="utf-8") as f:
        for _, la, lo in pts:
            f.write(f"{la:.6f},{lo:.6f}\n")


# --------------------------------------------------------------------------- senaryo arama

SARIKAVAK = (41.01, 29.64)
SILE = (41.10, 29.53)


def ring_normals(D: Data, poly: Polygon, i: int, k=2):
    ring = poly.rings[0]
    a, b = ring[(i - k) % len(ring)], ring[(i + k) % len(ring)]
    e, n = unit(*vec(a, b))
    return (n, -e), (-n, e)   # iki dik yön


def outward(D: Data, poly: Polygon, i: int, probe=40.0):
    """Sınır noktasında dışa bakan birim normal (çokgenin dışına) ya da None."""
    B = poly.rings[0][i]
    for ne, nn in ring_normals(D, poly, i):
        o = offset(B[0], B[1], ne * probe, nn * probe)
        inn = offset(B[0], B[1], -ne * probe, -nn * probe)
        if not poly.contains(o) and poly.contains(inn):
            return ne, nn
    return None


def candidates(D: Data, cls: int, centers, radius_km=12.0):
    out = []
    for poly in D.polys:
        if poly.cls != cls:
            continue
        ring = poly.rings[0]
        for i in range(0, len(ring), 1):
            dc = min(dist(ring[i], c) for c in centers)
            if dc <= radius_km * 1000:
                out.append((dc, poly, i))
    out.sort(key=lambda x: x[0])
    return out


def find_entry(D: Data):
    """(a)/(e): izinli devlet avlağından en yakın ava yasak alana dik giriş."""
    for dc, poly, i in candidates(D, 4, [SARIKAVAK, SILE]):
        n = outward(D, poly, i)
        if not n:
            continue
        B = poly.rings[0][i]
        start = offset(B[0], B[1], n[0] * 800, n[1] * 800)
        inner = offset(B[0], B[1], -n[0] * 200, -n[1] * 200)
        if D.vclass(start) != 1 or D.vclass(inner) != 4:
            continue
        if D.vdist(start, {4})[0] < 780 or D.vdist(inner, {4})[0] < 170:
            continue
        if D.vdist(start, {3, 5})[0] < 900:
            continue
        outer = sample_line(start, B, 50)[:-1]
        if any(D.vclass(p) != 1 for p in outer):
            continue
        far = [p for p in outer if dist(p, B) > 340]
        near = [p for p in outer if dist(p, B) <= 340]
        if not ids_ok(D, far, set(), max_level=1):
            continue
        if not ids_ok(D, near, {"yasak-yakin"}):
            continue
        if not ids_ok(D, sample_line(B, inner, 25)[1:], set()):
            continue
        return dict(poly=poly, B=B, n=n, start=start, inner=inner, center_dist=dc)
    raise SystemExit("(a) için uygun nokta bulunamadı")


def resample(path, step):
    out = [path[0]]
    acc = 0.0
    for a, b in zip(path, path[1:]):
        d = dist(a, b)
        while acc + d >= step:
            t = (step - acc) / d
            a = lerp(a, b, t)
            out.append(a)
            d = dist(a, b)
            acc = 0.0
        acc += d
    if dist(out[-1], path[-1]) > step * 0.3:
        out.append(path[-1])
    return out


def path_len(path):
    return sum(dist(a, b) for a, b in zip(path, path[1:]))


def parallel_path(D: Data, poly: Polygon, i0: int, length=2200.0, off=150.0):
    ring = poly.rings[0]
    seq = [ring[(i0 + j) % len(ring)] for j in range(len(ring))]
    bnd = [seq[0]]
    total = 0.0
    for a, b in zip(seq, seq[1:]):
        total += dist(a, b)
        bnd.append(b)
        if total >= length * 1.3:
            break
    if total < length * 1.3:
        return None
    bnd = resample(bnd, 20.0)
    pts = []
    for j in range(len(bnd)):
        a, b = bnd[max(0, j - 5)], bnd[min(len(bnd) - 1, j + 5)]
        e, n = unit(*vec(a, b))
        for ne, nn in ((n, -e), (-n, e)):
            o = offset(bnd[j][0], bnd[j][1], ne * off, nn * off)
            if D.vclass(o) != 4:
                pts.append(o)
                break
        else:
            return None
    # iteratif düzeltme + yumuşatma
    for _ in range(4):
        fixed = []
        for p in pts:
            d, q, _ = D.vdist(p, {4}, within=off * 3)
            if q is None:
                return None
            e, n = unit(*vec(q, p))
            if D.vclass(p) == 4:
                e, n = -e, -n
            fixed.append(offset(q[0], q[1], e * off, n * off))
        sm = []
        for j in range(len(fixed)):
            w = fixed[max(0, j - 4): j + 5]
            sm.append((sum(p[0] for p in w) / len(w), sum(p[1] for p in w) / len(w)))
        pts = sm
    pts = resample(pts, 20.0)
    # 2 km'ye kırp
    out = [pts[0]]
    for p in pts[1:]:
        if path_len(out + [p]) > length:
            break
        out.append(p)
    if path_len(out) < length * 0.95:
        return None
    # ±60 m salınım (yerel normale göre), ~400 m dalga boyu
    wob = []
    s = 0.0
    for j, p in enumerate(out):
        if j:
            s += dist(out[j - 1], p)
        a, b = out[max(0, j - 2)], out[min(len(out) - 1, j + 2)]
        e, n = unit(*vec(a, b))
        w = 60.0 * math.sin(2 * math.pi * s / 400.0)
        wob.append(offset(p[0], p[1], n * w, -e * w))
    return out, wob


def find_parallel(D: Data):
    tried = 0
    for dc, poly, i in candidates(D, 4, [SARIKAVAK, SILE], radius_km=15):
        if i % 4:
            continue
        tried += 1
        if tried > 400:
            break
        if not outward(D, poly, i):
            continue
        r = parallel_path(D, poly, i)
        if not r:
            continue
        base, wob = r
        ds = [D.vdist(p, {4}, within=600)[0] for p in wob]
        if min(ds) < 75 or max(ds) > 230:
            continue
        if any(D.vclass(p) not in (1, 2) for p in wob[::3]):
            continue
        if not ids_ok(D, wob[::3], {"yasak-yakin"}, required={"yasak-yakin"}):
            continue
        return dict(poly=poly, base=base, path=wob, dmin=min(ds), dmax=max(ds),
                    dmean=sum(ds) / len(ds), center_dist=dc)
    raise SystemExit("(b) için uygun sınır bulunamadı")


def find_village(D: Data):
    ref = (41.05, 29.60)
    villages = sorted((p for p in D.places if p["kind"] == "koy" and p["name"]),
                      key=lambda p: dist(ref, (p["lat"], p["lon"])))
    for v in villages[:150]:
        V = (v["lat"], v["lon"])
        for brg in range(0, 360, 30):
            start = bearing_pt(V, brg, 1000)
            close = bearing_pt(V, brg, 100)
            end = bearing_pt(V, brg + 70, 1000)
            path = sample_line(start, close, 50) + sample_line(close, end, 50)[1:]
            if any(D.vclass(p) not in (1, 2) for p in path):
                continue
            # en yakın köy hep bu köy olmalı; başka kural çıkmamalı
            bad = False
            for p in path:
                ch = evaluate(D, p)
                ids = {c[0] for c in ch}
                if not ids <= {"alan", "meskun"}:
                    bad = True
                    break
                r = D.nearest_place(p, {"koy"}, 2000)
                if r and r[0] is not v and abs(r[1] - dist(p, V)) > 1 and r[1] < 1000:
                    bad = True
                    break
            if bad or level_of(evaluate(D, start)) != 1:
                continue
            return dict(village=v, V=V, start=start, close=close, end=end, brg=brg)
    raise SystemExit("(c) için uygun köy bulunamadı")


def find_protected(D: Data):
    ref = [SARIKAVAK, SILE, (41.12, 29.37), (41.10, 29.20)]
    for dc, poly, i in candidates(D, 3, ref, radius_km=40):
        n = outward(D, poly, i)
        if not n:
            continue
        B = poly.rings[0][i]
        start = offset(B[0], B[1], n[0] * 1000, n[1] * 1000)
        close = offset(B[0], B[1], n[0] * 150, n[1] * 150)
        dclose = D.vdist(close, {3, 5})[0]
        if not (140 <= dclose <= 155):
            continue
        if D.vdist(start, {3, 5})[0] < 950:
            continue
        brg = math.degrees(math.atan2(n[0], n[1]))
        end = bearing_pt(B, brg + 60, 1000)
        if D.vdist(end, {3, 5})[0] < 700:
            continue
        path = sample_line(start, close, 50) + sample_line(close, end, 50)[1:]
        if any(D.vclass(p) not in (1, 2) for p in path):
            continue
        if not ids_ok(D, path, {"korunan"}):
            continue
        if level_of(evaluate(D, start)) != 1:
            continue
        return dict(poly=poly, B=B, n=n, start=start, close=close, end=end, dclose=dclose)
    raise SystemExit("(d) için uygun korunan alan bulunamadı")


def find_quiet_spot(D: Data):
    """(f): yasak alanlara >1,2 km, başka hiçbir kural tetiklenmeyen nokta."""
    for r in range(0, 15000, 500):
        for brg in range(0, 360, 20 if r else 360):
            for c0 in (SARIKAVAK, SILE):
                c = bearing_pt(c0, brg, r)
                if D.vclass(c) not in (1, 2):
                    continue
                if D.vdist(c, FORBIDDEN, within=2000)[0] < 1300:
                    continue
                for wb in range(0, 360, 45):
                    end = bearing_pt(c, wb, 300)
                    line = sample_line(c, end, 25)
                    if all(D.vclass(p) in (1, 2) for p in line) and ids_ok(D, line, set(), max_level=1) \
                            and D.vdist(end, FORBIDDEN, within=2000)[0] >= 1200:
                        return dict(center=c, end=end, walk_brg=wb,
                                    dforb=D.vdist(c, FORBIDDEN, within=3000)[0])
    raise SystemExit("(f) için sakin nokta bulunamadı")


# --------------------------------------------------------------------------- zaman çizelgesi

def timeline(D: Data, pts, events=()):
    """Taklit edilen seviye değişimleri: [(t, seviye, kimlikler, açıklamalar, lat, lon)]."""
    out = []
    last = None
    for t, la, lo in pts:
        ch = evaluate(D, (la, lo))
        lvl = level_of(ch)
        sig = (lvl, tuple(sorted(c[0] for c in ch if c[1] >= 2)))
        if sig != last:
            out.append((t, lvl, [c for c in ch if c[1] >= 2], la, lo))
            last = sig
    return out


def fmt_t(t):
    return f"{int(t // 60):02d}:{int(t % 60):02d}"


def print_timeline(tl, events=()):
    rows = [(t, "evt", txt) for t, txt in events]
    for t, lvl, ch, la, lo in tl:
        desc = "; ".join(c[2] for c in ch) or "-"
        rows.append((t, "lvl", f"{LEVELS[lvl]:<9} {desc}  @ {la:.5f},{lo:.5f}"))
    for t, kind, txt in sorted(rows, key=lambda r: (r[0], r[1])):
        print(f"    +{fmt_t(t)}  {'»' if kind == 'evt' else ' '} {txt}")


def first(tl, level):
    for t, lvl, ch, la, lo in tl:
        if lvl >= level:
            return t, (la, lo)
    return None, None


def crossing(D, a, b, cls=4, tol=0.5):
    """a (dışarıda) -> b (içeride) doğrusu üzerinde vektör sınırının geçildiği nokta."""
    inside = lambda p: any(pl.cls == cls and pl.contains(p) for pl in D.polys)
    lo, hi = 0.0, 1.0
    assert not inside(a) and inside(b)
    while dist(lerp(a, b, lo), lerp(a, b, hi)) > tol:
        m = (lo + hi) / 2
        if inside(lerp(a, b, m)):
            hi = m
        else:
            lo = m
    return lerp(a, b, hi)


def raster_crossing(D, a, b, cls=4):
    for p in resample([a, b], 2.0):
        if D.zone(p) == cls:
            return p
    return None


def shapely_check(D, pts, cls):
    if SG is None:
        return None
    polys = []
    for pl in D.polys:
        if pl.cls == cls:
            polys.append(SG.Polygon([(lo, la) for la, lo in pl.rings[0]],
                                    [[(lo, la) for la, lo in r] for r in pl.rings[1:]]))
    from shapely.ops import unary_union
    u = unary_union(polys)
    lat0 = sum(p[1] for p in pts) / len(pts)
    k = mlon(lat0)
    from shapely import affinity
    um = affinity.scale(u, xfact=k, yfact=M_LAT, origin=(0, 0))
    inside = [u.contains(SG.Point(lo, la)) for _, la, lo in pts]
    dmin = min(um.exterior.distance(SG.Point(lo * k, la * M_LAT)) if hasattr(um, "exterior")
               else um.boundary.distance(SG.Point(lo * k, la * M_LAT)) for _, la, lo in pts)
    return any(inside), dmin


# --------------------------------------------------------------------------- ana akış

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--seed", type=int, default=2026)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(args.seed)
    D = Data()
    ok = True
    print(f"Veri: {len(D.polys)} çokgen, {len(D.places)} yer, shapely: {'var' if SG else 'yok'}")

    def save(stem, name, desc, tr: Track, txt_parts=None):
        write_gpx(os.path.join(args.out, stem + ".gpx"), name, desc, tr.pts)
        write_txt(os.path.join(args.out, stem + ".txt"), tr.pts)
        for suffix, part in (txt_parts or {}).items():
            write_txt(os.path.join(args.out, f"{stem}_{suffix}.txt"), part)
        dur = tr.pts[-1][0]
        print(f"  -> {stem}.gpx  {len(tr.pts)} nokta, {fmt_t(dur)} dk, iz uzunluğu {path_len([(p[1], p[2]) for p in tr.pts]):.0f} m (GPS gürültüsü dahil)")

    # ---------------- (a)
    print("\n[01] Yasak alana giriş")
    E = find_entry(D)
    B, n = E["B"], E["n"]
    back = offset(B[0], B[1], n[0] * 400, n[1] * 400)
    cross = crossing(D, E["start"], E["inner"])
    rc = raster_crossing(D, E["start"], E["inner"])
    tr = Track(rng, E["start"]).mark("Başlangıç: devlet avlağı, sınıra 800 m")
    tr.walk_to(E["inner"]).mark("Yasak alanın 200 m içi; geri dönüş")
    tr.walk_to(back).mark("Sınırdan 400 m dışarıda; bitiş")
    print(f"  Başlangıç {E['start'][0]:.5f},{E['start'][1]:.5f}  sınıf={D.vclass(E['start'])} "
          f"(yasak sınıra {D.vdist(E['start'], {4})[0]:.0f} m), Sarıkavak/Şile merkezine {E['center_dist']/1000:.1f} km")
    print(f"  Vektör sınır geçişi {cross[0]:.5f},{cross[1]:.5f}: başlangıçtan {dist(E['start'], cross):.0f} m "
          f"(~{fmt_t(dist(E['start'], cross) / SPEED)})")
    if rc:
        print(f"  Raster (uygulama) sınır geçişi: başlangıçtan {dist(E['start'], rc):.0f} m "
              f"(vektörden fark {dist(cross, rc):.0f} m)")
    print(f"  En derin nokta {E['inner'][0]:.5f},{E['inner'][1]:.5f}: sınıf={D.vclass(E['inner'])}, "
          f"sınıra {D.vdist(E['inner'], {4})[0]:.0f} m içeride")
    inside_any = any(D.vclass((la, lo)) == 4 for _, la, lo in tr.pts)
    print(f"  DOĞRULAMA sınıf-4 içine giriyor mu: {'EVET' if inside_any else 'HAYIR'}")
    ok &= inside_any
    sc = shapely_check(D, tr.pts, 4)
    if sc:
        print(f"  shapely: içeride nokta var={sc[0]}")
        ok &= sc[0]
    tl = timeline(D, tr.pts)
    print_timeline(tl, tr.events)
    save("01_yasak_alana_giris", "01 Yasak alana giriş",
         "Devlet avlağından ava yasak alana dik giriş, 200 m içeri, geri çıkış", tr)
    entry = E

    # ---------------- (b)
    print("\n[02] Sınır boyunca")
    P = find_parallel(D)
    tr = Track(rng, P["path"][0]).mark("Başlangıç: yasak sınırına ~150 m, paralel yürüyüş")
    tr.walk_path(P["path"][1:]).mark("Bitiş")
    ds = [D.vdist((la, lo), {4}, within=600)[0] for _, la, lo in tr.pts]
    inside = any(D.vclass((la, lo)) == 4 for _, la, lo in tr.pts)
    print(f"  Başlangıç {P['path'][0][0]:.5f},{P['path'][0][1]:.5f}  bitiş {P['path'][-1][0]:.5f},{P['path'][-1][1]:.5f}")
    print(f"  Sınıra paralel taban hat {path_len(P['base']):.0f} m (salınımlı yürüyüş {path_len(P['path']):.0f} m); yasak sınırına uzaklık min {min(ds):.0f} / "
          f"ort {sum(ds)/len(ds):.0f} / maks {max(ds):.0f} m; içeri giriş: {'VAR (HATA)' if inside else 'yok'}")
    ok &= not inside and max(ds) < 300
    print_timeline(timeline(D, tr.pts), tr.events)
    save("02_sinir_boyunca", "02 Sınır boyunca", "Ava yasak alan sınırına ~150 m paralel, ±60 m salınım", tr)

    # ---------------- (c)
    print("\n[03] Köy yakını")
    Vd = find_village(D)
    V = Vd["V"]
    tr = Track(rng, Vd["start"]).mark(f"Başlangıç: {Vd['village']['name']} köyüne 1000 m")
    tr.walk_to(Vd["close"]).mark("Köy noktasına 100 m (en yakın)")
    tr.walk_to(Vd["end"]).mark("Köyden 1000 m; bitiş")
    dmin = min(dist((la, lo), V) for _, la, lo in tr.pts)
    print(f"  Köy: {Vd['village']['name']} ({V[0]:.5f},{V[1]:.5f}), yaklaşma yönü {Vd['brg']}°, en yakın {dmin:.0f} m")
    t300 = next(t for t, la, lo in tr.pts if dist((la, lo), V) <= 300 + ACC)
    print(f"  300 m çizgisi +{fmt_t(t300)}'de geçiliyor")
    print_timeline(timeline(D, tr.pts), tr.events)
    save("03_koy_yakini", "03 Köy yakını", f"{Vd['village']['name']} köyüne 1 km'den 100 m'ye yaklaşma ve uzaklaşma", tr)

    # ---------------- (d)
    print("\n[04] Korunan alan tamponu")
    K = find_protected(D)
    tr = Track(rng, K["start"]).mark("Başlangıç: korunan alana 1000 m")
    tr.walk_to(K["close"]).mark("Korunan alan sınırına ~150 m (en yakın)")
    tr.walk_to(K["end"]).mark("Bitiş")
    ds = [D.vdist((la, lo), {3, 5}, within=2000)[0] for _, la, lo in tr.pts]
    inside = any(D.vclass((la, lo)) in (3, 5) for _, la, lo in tr.pts)
    print(f"  Korunan alan sınırı {K['B'][0]:.5f},{K['B'][1]:.5f}; en yakın nokta {K['close'][0]:.5f},{K['close'][1]:.5f}")
    print(f"  DOĞRULAMA sınıf-3'e en kısa uzaklık: {min(ds):.0f} m (≤150 hedef), içeri giriş: {'VAR' if inside else 'yok'}")
    rd = D.zone_nearest(K["close"], 400, (3, 5))
    print(f"  Raster (uygulama) uzaklığı en yakın noktada: {rd:.0f} m" if rd is not None else "  raster: yok")
    ok &= min(ds) <= 160 and not inside
    sc = shapely_check(D, tr.pts, 3)
    if sc:
        print(f"  shapely: içeri={sc[0]}, min uzaklık={sc[1]:.0f} m")
        ok &= (not sc[0]) and sc[1] <= 160
    t300 = next((t for (t, la, lo), d in zip(tr.pts, ds) if d <= 300), None)
    print(f"  300 m tamponuna giriş (vektör) +{fmt_t(t300)}")
    print_timeline(timeline(D, tr.pts), tr.events)
    save("04_korunan_alan_tamponu", "04 Korunan alan tamponu", "Korunan alan sınırına 150 m yaklaşıp uzaklaşma", tr)

    # ---------------- (e)
    print("\n[05] GPS kesintisi")
    E = entry
    B, n = E["B"], E["n"]
    gap_start = offset(B[0], B[1], n[0] * 100, n[1] * 100)
    gap_end = lerp(gap_start, E["inner"], (180 * SPEED) / dist(gap_start, E["inner"]))
    back = offset(B[0], B[1], n[0] * 400, n[1] * 400)
    tr = Track(rng, E["start"]).mark("Başlangıç (01 ile aynı hat)")
    tr.walk_to(gap_start).mark("Son konum: sınıra 100 m dışarıda")
    i_gap = len(tr.pts)
    tr.gap_walk_to(gap_end).mark("Konum geri geldi: yasak alanın içinde")
    tr.walk_to(E["inner"]).walk_to(back).mark("Bitiş")
    print(f"  Kesinti +{fmt_t(tr.pts[i_gap - 1][0])} → +{fmt_t(tr.pts[i_gap][0])} "
          f"({tr.pts[i_gap][0] - tr.pts[i_gap - 1][0]:.0f} s), atlanan mesafe {dist(gap_start, gap_end):.0f} m")
    print(f"  İlk yeni nokta sınıf={D.vclass(gap_end)}, sınırdan {D.vdist(gap_end, {4})[0]:.0f} m içeride")
    ok &= D.vclass(gap_end) == 4
    print_timeline(timeline(D, tr.pts), tr.events)
    save("05_gps_kesintisi", "05 GPS kesintisi", "01 ile aynı hat; yasak alana girmeden önce 3 dk konum yok", tr,
         txt_parts={"a_kesinti_oncesi": tr.pts[:i_gap], "b_kesinti_sonrasi": tr.pts[i_gap:]})

    # ---------------- (f)
    print("\n[06] Hareketsiz pusu")
    Q = find_quiet_spot(D)
    tr = Track(rng, Q["center"]).mark("Pusu başlıyor (±5 m titreşim)")
    tr.stand(600).mark("10 dk bitti; 300 m yürüyüş")
    i_walk = len(tr.pts)
    tr.walk_to(Q["end"]).mark("Bitiş")
    c = Q["center"]
    dj = max(dist(c, (la, lo)) for _, la, lo in tr.pts[:i_walk])
    dforb_txt = ">3 km" if Q["dforb"] == math.inf else f"{Q['dforb']:.0f} m"
    print(f"  Pusu noktası {c[0]:.5f},{c[1]:.5f} sınıf={D.vclass(c)}; en yakın yasak/korunan alan {dforb_txt}; "
          f"titreşim maks {dj:.1f} m; yürüyüş yönü {Q['walk_brg']}°")
    print("  Beklenen: +03:00 civarı 'pusu: pil tasarrufu' (AppModel.updatePowerMode: 3 dk, <20 m, yasağa >600 m);"
          " yürüyüşte ~20 m sonra tam hassasiyete dönüş")
    ok &= Q["dforb"] > 1000 and dj <= 5.01
    print_timeline(timeline(D, tr.pts), tr.events)
    save("06_hareketsiz_pusu", "06 Hareketsiz pusu", "10 dk ±5 m titreşimle bekleme, sonra 300 m yürüyüş", tr,
         txt_parts={"yuruyus": tr.pts[i_walk - 1:]})
    print(f"\n  06 için simctl sabit konum: xcrun simctl location booted set {c[0]:.6f},{c[1]:.6f}")

    print("\nDOĞRULAMA:", "TAMAM" if ok else "BAŞARISIZ")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
