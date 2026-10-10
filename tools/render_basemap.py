#!/usr/bin/env python3
"""
İstanbul ili için çevrimdışı topoğrafik altlık haritası (raster karo paketi) üretir.

OSM / OpenTopoMap / Apple karolarını toplu indirmek kullanım koşullarına aykırı olduğundan
karolar açık veriden burada çizilir:

  * OpenStreetMap (Geofabrik Türkiye özeti, .osm.pbf; küçük denemeler için .osm XML de olur):
    arazi örtüsü, su, yollar (otoyoldan patikaya), demiryolu, yerleşim adları, zirveler, il sınırı.
  * Copernicus DEM GLO-30 (AWS açık veri, s3://copernicus-dem-30m, herkese açık HTTPS):
    tepe gölgelendirmesi (hillshade) ve eş yükselti eğrileri (20 m, 100 m'de etiketli ana eğri).

Çıktı, uygulamanın mevcut tek dosyalık karo paketi biçimidir ("AVTP", bkz.
ios/AvHaritasi/Model/TilePack.swift ve tools/generate_assets.py:write_pack):

    "AVTP" | u32 sürüm=1 | u32 adet |
    adet x (u8 z, 3 bayt boşluk, u32 x, u32 y, u64 ofset, u32 uzunluk) | karo verileri

Karolar 256 px, Web Mercator XYZ (MKTileOverlay tileSize = 256). Karo verisi PNG ya da JPEG
olabilir (MapKit ikisini de doğrudan çözer; ilk baytlardan ayırt edilir):
  * en çok 256 farklı renk içeren karolar kayıpsız 8 bit paletli PNG (renk azaltma YOK; renkler
    zaten <= 256 ise tam karşılığı yazılır),
  * gölgelendirme içeren karolar JPEG (--jpeg-quality, varsayılan 78).

İl sınırının (OSM admin_level=4 "İstanbul") tamamen dışında kalan ve tamamen deniz olan karolar
pakete yazılmaz; uygulama bulamadığı karo için deniz rengi (MANIFEST_SEA_COLOR) göstermelidir.

Bağımlılıklar
  Komut satırı: osmium-tool (Ubuntu: apt-get install osmium-tool)
  Yazı tipi:    DejaVu Sans (Ubuntu: fonts-dejavu-core; Türkçe karakterleri içerir)
  Python 3.10+: pip install numpy scipy shapely pycairo pillow rasterio scikit-image
                (pycairo derlemesi için: apt-get install libcairo2-dev pkg-config)

Kullanım (tam il):
  python3 tools/render_basemap.py --osm turkey-latest.osm.pbf --cache veri/basemap --out cikti \\
      --pack istanbul_topo_low:8-12 --pack istanbul_topo_high:13-15 \\
      --url-base https://github.com/oguzbay-del/av-harita-veri/releases/download/basemap-istanbul

Küçük deneme (Şile/Ağva, il sınırı aranmaz, örnek PNG ve kontak tabakası yazılır):
  curl -o agva.osm "https://api.openstreetmap.org/api/0.6/map?bbox=29.75,41.08,29.95,41.20"
  python3 tools/render_basemap.py --osm agva.osm --bbox 29.75,41.08,29.95,41.20 --no-province \\
      --cache veri/basemap --out deneme --pack deneme:11-15 --samples deneme/ornekler
"""
import argparse
import datetime
import hashlib
import io
import json
import math
import multiprocessing
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

import cairo
import numpy as np
import shapely
from PIL import Image
from scipy import ndimage
from scipy.interpolate import RectBivariateSpline
from shapely.geometry import box, shape
from skimage.measure import find_contours

# ---------------------------------------------------------------------------
# Sabitler
# ---------------------------------------------------------------------------
PROVINCE_BBOX = (27.95, 40.80, 29.95, 41.60)   # w, s, e, n (İstanbul ili ve kıyıları)
OSM_MARGIN = 0.25                                # OSM verisinin il kutusundan taşan payı (derece)
PROVINCE_NAMES = {"İstanbul", "Istanbul"}

ATTRIBUTION_TR = ("© OpenStreetMap katkıcıları (ODbL) · Yükselti: Copernicus DEM GLO-30 © DLR e.V. "
                  "2010-2014 ve © Airbus Defence and Space GmbH 2014-2018, Copernicus (AB ve ESA)")
ATTRIBUTION_EN = ("© OpenStreetMap contributors (ODbL) · Elevation: Copernicus DEM GLO-30 © DLR e.V. "
                  "2010-2014 and © Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS "
                  "by the European Union and ESA")

DEM_URL = ("https://copernicus-dem-30m.s3.amazonaws.com/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM.tif")

WC_URL = ("https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
          "ESA_WorldCover_10m_2021_v200_{ns}{lat:02d}{ew}{lon:03d}_Map.tif")
WC_ATTR_TR = (" · Arazi örtüsü: © ESA WorldCover 2021 (CC BY 4.0), Copernicus Sentinel verisi "
              "(2021) ESA WorldCover konsorsiyumu tarafından işlenmiştir")
WC_ATTR_EN = (" · Land cover: © ESA WorldCover project 2021 (CC BY 4.0) / Contains modified "
              "Copernicus Sentinel data (2021) processed by ESA WorldCover consortium")
WC_CLASSES = {10: "forest", 20: "scrub", 30: "meadow", 40: "farmland", 90: "wetland"}

R = 6378137.0
HALF = math.pi * R
WORLD = 2 * HALF
TILE = 256
META = 8        # metakaro: 8x8 karo birlikte çizilir, sonra kesilir
BUF = 64        # metakaro kenar payı (px)
FONT = "DejaVu Sans"


def rgb(h, a=1.0):
    h = h.lstrip("#")
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, a)


# ---------------------------------------------------------------------------
# Biçem (avcı odaklı, sade topoğrafik)
# ---------------------------------------------------------------------------
SEA = "#a9cfe6"
LAND = "#f3f0e7"
MANIFEST_SEA_COLOR = SEA

FILL = {   # çizim sırası önemli
    "farmland": "#f2edd2",
    "farmyard": "#eadbc8",
    "meadow": "#e2edc8",
    "orchard": "#d6e6b3",
    "scrub": "#cde0ae",
    "forest": "#aed192",
    "wetland": "#d5e8e3",
    "sand": "#f1e4bd",
    "bare": "#e2dcd3",
    "residential": "#e6dcd7",
    "industrial": "#e4d8e2",
    "cemetery": "#cbdcc4",
    "park": "#c9e7b3",
}
POLY_ORDER = list(FILL)
WATER = SEA
BUILDING = ("#d4c3b1", "#b09a83")

# Yol sınıfları: (dolgu, kılıf, düşük yakınlıkta (kılıfsız) renk, z8..z15 genişlikleri px)
ROADS = {
    "motorway":  ("#e9806c", "#a8443a", "#d9604f", [1.4, 1.6, 2.0, 2.6, 3.2, 4.2, 5.6, 7.6]),
    "trunk":     ("#f3a66b", "#ad5a2c", "#e08a4c", [1.2, 1.4, 1.8, 2.4, 3.0, 3.9, 5.2, 7.0]),
    "primary":   ("#f8c870", "#a4762a", "#dda24a", [0.0, 1.0, 1.4, 2.0, 2.6, 3.5, 4.8, 6.6]),
    "secondary": ("#f7e590", "#97883a", "#c9b55a", [0.0, 0.0, 1.0, 1.5, 2.2, 3.1, 4.3, 6.0]),
    "tertiary":  ("#ffffff", "#8d8d86", "#b4aea2", [0.0, 0.0, 0.0, 1.0, 1.5, 2.4, 3.4, 5.0]),
    "minor":     ("#ffffff", "#9d9d96", "#bdb7ab", [0.0, 0.0, 0.0, 0.0, 0.8, 1.3, 2.3, 3.8]),
    "service":   ("#ffffff", "#a8a8a0", "#c4beb2", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.2, 2.0]),
}
ROAD_ORDER = ["service", "minor", "tertiary", "secondary", "primary", "trunk", "motorway"]
CASING_FROM = {"motorway": 11, "trunk": 11, "primary": 12, "secondary": 12,
               "tertiary": 13, "minor": 14, "service": 14}
TRACK = ("#87562a", [0, 0, 0, 0, 0.8, 1.1, 1.5, 1.9])      # orman / tarla yolu (kesik çizgi)
PATH = ("#b4432a", [0, 0, 0, 0, 0, 0.8, 1.0, 1.3])         # patika (noktalı)
RIVER = ("#6fa9d8", [0, 0, 0.8, 1.0, 1.3, 1.8, 2.4, 3.2])
STREAM = ("#86bbe3", [0, 0, 0, 0, 0.6, 0.8, 1.0, 1.4])
RAIL = "#6a6a6a"
POWER = "#8c8c8c"
CLIFF = "#7a5a3a"
CONTOUR = (0.56, 0.40, 0.24)
PROVINCE_LINE = "#8a4f9e"

# Görünürlük (en küçük yakınlaştırma)
MINZOOM = {"motorway": 8, "trunk": 8, "primary": 9, "secondary": 10, "tertiary": 11,
           "minor": 12, "service": 14, "track": 12, "path": 13, "rail": 9, "river": 10,
           "stream": 12, "power": 13, "cliff": 13, "building": 14, "spring": 14}

# Eş yükselti eğrileri: z -> (aralık, ana eğri aralığı, etiket?)
CONTOURS = {10: (100, 0, False), 11: (100, 0, False), 12: (50, 100, False),
            13: (20, 100, True), 14: (20, 100, True), 15: (20, 100, True)}
# Tepe gölgelendirmesi: z -> (düşey abartma, gölge gücü, ışık gücü)
HILLSHADE = {8: (3.0, 0.50, 0.2), 9: (2.7, 0.50, 0.2), 10: (2.4, 0.50, 0.2),
             11: (2.2, 0.50, 0.2), 12: (2.0, 0.48, 0.2), 13: (1.6, 0.44, 0.18),
             14: (1.45, 0.42, 0.18), 15: (1.35, 0.40, 0.18)}
# Yüzey modeli (DSM) ağaç/yapı yüksekliğini de içerir: büyük yakınlıkta DEM'in kendi
# çözünürlüğünden (30 m) ince ayrıntı uydurulmasın diye ek yumuşatma (metre, gauss sigma)
HS_SMOOTH_M = 40.0
CONTOUR_SMOOTH_M = 60.0

# Yer adları: tür -> (en küçük z, öncelik, kalın?, eğik?, renk, boyut z<=11, boyut z12, boyut z>=13)
PLACES = {
    "city":         (8, 100, True, False, "#1f1f1f", 15.0, 16.0, 17.0),
    "town":         (9, 90, True, False, "#222222", 11.5, 13.0, 14.0),
    "suburb":       (11, 66, True, False, "#4a4a4a", 10.0, 10.5, 11.5),
    "village":      (10, 70, True, False, "#2a2a2a", 9.5, 10.5, 12.0),
    "island":       (11, 62, False, True, "#333333", 9.5, 10.5, 11.5),
    "hamlet":       (13, 50, False, False, "#3a3a3a", 9.5, 9.5, 10.0),
    "locality":     (13, 40, False, True, "#6b5940", 9.5, 9.5, 10.0),
    "quarter":      (14, 36, False, False, "#5e5e5e", 9.5, 9.5, 10.0),
    "neighbourhood": (14, 35, False, False, "#5e5e5e", 9.5, 9.5, 10.0),
    "isolated_dwelling": (15, 30, False, False, "#555555", 9.0, 9.0, 9.0),
}
PEAK = (11, 60, "#6b3d1f")
WATER_LABEL = (10, 55, "#2d6c9f")

# ---------------------------------------------------------------------------
# Web Mercator
# ---------------------------------------------------------------------------


def merc_xy(lon, lat):
    lon = np.asarray(lon, float)
    lat = np.clip(np.asarray(lat, float), -85.0511, 85.0511)
    return R * np.radians(lon), R * np.log(np.tan(np.pi / 4 + np.radians(lat) / 2))


def merc_coords(c):
    x, y = merc_xy(c[:, 0], c[:, 1])
    return np.column_stack([x, y])


def inv_lat(y):
    return np.degrees(2 * np.arctan(np.exp(np.asarray(y) / R)) - np.pi / 2)


def res_m(z):
    return WORLD / (TILE * 2 ** z)


def tile_box_m(z, x, y):
    s = TILE * res_m(z)
    left = -HALF + x * s
    top = HALF - y * s
    return left, top - s, left + s, top


def lonlat_tile(lon, lat, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


# ---------------------------------------------------------------------------
# AVTP paketi (tools/generate_assets.py:write_pack ile aynı biçim)
# ---------------------------------------------------------------------------


def write_pack(path, tiles):
    """tiles: [(z, x, y, bytes)]. Biçim (little endian): "AVTP" | u32 sürüm=1 | u32 adet |
    adet x (u8 z, 3 bayt boşluk, u32 x, u32 y, u64 ofset, u32 uzunluk) | veri"""
    tiles = sorted(tiles, key=lambda t: (t[0], t[1], t[2]))
    header = 12 + 24 * len(tiles)
    with open(path, "wb") as fh:
        fh.write(b"AVTP" + struct.pack("<II", 1, len(tiles)))
        off = header
        for z, x, y, data in tiles:
            fh.write(struct.pack("<B3xIIQI", z, x, y, off, len(data)))
            off += len(data)
        for *_, data in tiles:
            fh.write(data)


def read_pack(path):
    with open(path, "rb") as fh:
        buf = fh.read()
    assert buf[:4] == b"AVTP", path
    _, n = struct.unpack_from("<II", buf, 4)
    out = {}
    for i in range(n):
        z, x, y, off, ln = struct.unpack_from("<B3xIIQI", buf, 12 + 24 * i)
        out[(z, x, y)] = buf[off:off + ln]
    return out


# ---------------------------------------------------------------------------
# İndirme
# ---------------------------------------------------------------------------


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def download(url, dest, missing_ok=False):
    if os.path.exists(dest):
        return dest
    if missing_ok and os.path.exists(dest + ".yok"):
        return None
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    tmp = dest + ".part"
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as fh:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
            os.replace(tmp, dest)
            return dest
        except urllib.error.HTTPError as e:
            if e.code in (403, 404) and missing_ok:
                open(dest + ".yok", "w").close()   # bu karo yok (tamamen deniz)
                return None
            err = e
        except (urllib.error.URLError, OSError) as e:
            err = e
        log(f"  indirme hatası ({attempt + 1}/5) {url}: {err}")
        time.sleep(5 * (attempt + 1))
    raise SystemExit(f"İndirilemedi: {url}")


# ---------------------------------------------------------------------------
# OSM
# ---------------------------------------------------------------------------
OSM_FILTERS = [
    "nwr/landuse", "nwr/natural", "nwr/leisure=park,garden,golf_course",
    "nwr/water", "nwr/wetland", "nwr/building", "nwr/military", "nwr/amenity=grave_yard",
    "nwr/waterway", "nwr/place", "w/highway", "w/railway", "w/power=line,minor_line",
    "nwr/aeroway=aerodrome",
]
OSM_EXPORT_CFG = {
    "attributes": {"type": True, "id": True},
    "linear_tags": ["highway", "railway", "waterway", "natural=coastline", "natural=cliff", "power"],
    "area_tags": ["landuse", "natural", "leisure", "water", "wetland", "building", "military",
                  "amenity", "place", "aeroway", "waterway=riverbank"],
}


def run(cmd):
    log("  $", " ".join(cmd))
    subprocess.run(cmd, check=True)


def osm_prepare(src, bbox, work, want_province):
    """osmium ile kutuyu keser, gerekli etiketleri süzer, GeoJSON satırlarına çevirir."""
    os.makedirs(work, exist_ok=True)
    cfg = os.path.join(work, "export.json")
    with open(cfg, "w") as fh:
        json.dump(OSM_EXPORT_CFG, fh)
    area = os.path.join(work, "alan.osm.pbf")
    sel = os.path.join(work, "secili.osm.pbf")
    out = os.path.join(work, "secili.geojsonseq")
    b = ",".join(f"{v:.4f}" for v in bbox)
    run(["osmium", "extract", "-b", b, "-s", "smart", src, "-o", area, "--overwrite"])
    run(["osmium", "tags-filter", area, *OSM_FILTERS, "-o", sel, "--overwrite"])
    run(["osmium", "export", sel, "-c", cfg, "-f", "geojsonseq", "-o", out, "--overwrite"])
    prov = None
    if want_province:
        adm = os.path.join(work, "il.osm.pbf")
        adm_out = os.path.join(work, "il.geojsonseq")
        pcfg = os.path.join(work, "export_il.json")
        with open(pcfg, "w") as fh:
            json.dump({"attributes": {"type": True, "id": True}, "linear_tags": False,
                       "area_tags": ["boundary"]}, fh)
        run(["osmium", "tags-filter", src, "r/admin_level=4", "-o", adm, "--overwrite"])
        run(["osmium", "export", adm, "-c", pcfg, "-f", "geojsonseq", "-o", adm_out, "--overwrite"])
        prov = adm_out
    return out, prov


def load_province(path):
    best = None
    for line in open(path, encoding="utf-8"):
        f = json.loads(line.strip("\x1e\n"))
        p = f["properties"]
        if p.get("admin_level") == "4" and (p.get("name") in PROVINCE_NAMES or
                                            p.get("name:en") == "Istanbul Province" or
                                            p.get("name:en") == "Istanbul"):
            g = shape(f["geometry"])
            if best is None or g.area > best.area:
                best = g
    if best is None:
        raise SystemExit("İl sınırı (admin_level=4 İstanbul) bulunamadı")
    return shapely.make_valid(shapely.transform(best, merc_coords))


ROAD_CLASS = {
    "motorway": "motorway", "motorway_link": "motorway", "trunk": "trunk", "trunk_link": "trunk",
    "primary": "primary", "primary_link": "primary", "secondary": "secondary",
    "secondary_link": "secondary", "tertiary": "tertiary", "tertiary_link": "tertiary",
    "unclassified": "minor", "residential": "minor", "living_street": "minor", "road": "minor",
    "pedestrian": "minor", "service": "service", "track": "track", "path": "path",
    "footway": "path", "bridleway": "path", "cycleway": "path", "steps": "path",
}


def classify_area(p):
    if p.get("building", "no") != "no":
        return "building"
    lu, nat, le = p.get("landuse"), p.get("natural"), p.get("leisure")
    if (nat == "water" or lu in ("reservoir", "basin") or p.get("waterway") == "riverbank"
            or ("water" in p and nat is None and lu is None)):
        return "water"
    if nat == "wetland" or "wetland" in p:
        return "wetland"
    if lu == "military" or "military" in p:
        return "military"
    if lu == "forest" or nat == "wood":
        return "forest"
    if nat in ("scrub", "heath"):
        return "scrub"
    if lu in ("orchard", "vineyard"):
        return "orchard"
    if lu in ("meadow", "grass", "village_green") or nat == "grassland":
        return "meadow"
    if lu in ("farmland", "allotments", "greenhouse_horticulture", "plant_nursery"):
        return "farmland"
    if lu == "farmyard":
        return "farmyard"
    if nat in ("beach", "sand"):
        return "sand"
    if nat in ("bare_rock", "scree", "shingle") or lu in ("quarry", "landfill", "construction",
                                                          "brownfield"):
        return "bare"
    if lu == "residential":
        return "residential"
    if lu in ("industrial", "commercial", "retail", "railway") or p.get("aeroway") == "aerodrome":
        return "industrial"
    if lu == "cemetery" or p.get("amenity") == "grave_yard":
        return "cemetery"
    if le in ("park", "garden", "golf_course"):
        return "park"
    return None


def classify_line(p):
    hw = p.get("highway")
    tunnel = p.get("tunnel") in ("yes", "culvert", "building_passage")
    if hw in ROAD_CLASS:
        c = ROAD_CLASS[hw]
        if c == "track" and p.get("tracktype") == "grade1":
            return "minor", tunnel
        return c, tunnel
    if p.get("railway") in ("rail", "narrow_gauge", "light_rail", "preserved") and not tunnel:
        return "rail", False
    ww = p.get("waterway")
    if ww in ("river", "canal"):
        return "river", tunnel
    if ww in ("stream", "ditch", "drain", "brook"):
        return "stream", tunnel
    if p.get("natural") == "coastline":
        return "coastline", False
    if p.get("natural") == "cliff":
        return "cliff", False
    if p.get("power") in ("line", "minor_line"):
        return "power", False
    return None, False


def parse_ele(v):
    if not v:
        return None
    try:
        return float(str(v).replace(",", ".").split()[0].rstrip("m"))
    except ValueError:
        return None


def load_osm(path):
    polys = {k: [] for k in POLY_ORDER + ["water", "building", "military"]}
    lines = {k: [] for k in list(ROADS) + ["track", "path", "rail", "river", "stream",
                                           "coastline", "cliff", "power"]}
    tunnels = {k: [] for k in lines}
    points = []      # (tür, ad, x, y, ele, alan_m2)
    springs = []
    n = 0
    for line in open(path, encoding="utf-8"):
        line = line.strip("\x1e\n")
        if not line:
            continue
        f = json.loads(line)
        n += 1
        p = f["properties"]
        gt = f["geometry"]["type"]
        name = p.get("name:tr") or p.get("name")
        if gt == "Point":
            lon, lat = f["geometry"]["coordinates"]
            x, y = merc_xy(lon, lat)
            if p.get("place") in PLACES and name:
                points.append((p["place"], name, float(x), float(y), None, 0.0))
            elif p.get("natural") in ("peak", "hill", "volcano"):
                points.append(("peak", name, float(x), float(y), parse_ele(p.get("ele")), 0.0))
            elif p.get("natural") == "spring":
                springs.append((float(x), float(y), name))
            continue
        g = shapely.transform(shape(f["geometry"]), merc_coords)
        if gt in ("Polygon", "MultiPolygon"):
            if not g.is_valid:
                g = shapely.make_valid(g)
            if p.get("place") in PLACES and name:
                rp = g.point_on_surface()
                points.append((p["place"], name, rp.x, rp.y, None, g.area))
            c = classify_area(p)
            if c:
                polys[c].append(g)
                if c == "water" and name and g.area > 2e4:
                    rp = g.point_on_surface()
                    points.append(("water", name, rp.x, rp.y, None, g.area))
        elif gt in ("LineString", "MultiLineString"):
            c, tunnel = classify_line(p)
            if c:
                (tunnels if tunnel else lines)[c].append(g)
    log(f"  OSM: {n} nesne; " + ", ".join(f"{k}={len(v)}" for k, v in {**polys, **lines}.items() if v))
    return polys, lines, tunnels, points, springs


def build_land(coast, frame):
    """Kıyı çizgilerinden kara poligonları: çerçeve kıyılarla bölünür, her parça kıyı
    yönüne (kara solda) göre oylanır."""
    if not coast:
        log("  kıyı çizgisi yok: tüm alan kara sayılıyor")
        return frame
    lines = shapely.union_all(shapely.intersection(np.array(coast, dtype=object), frame.buffer(1)))
    pieces = list(shapely.get_parts(shapely.polygonize([shapely.union_all([frame.boundary, lines])])))
    pieces = [pc for pc in pieces if pc.area > 1]
    pts_l, pts_r = [], []
    for g in coast:
        for part in shapely.get_parts(g):
            c = np.asarray(part.coords)
            if len(c) < 2:
                continue
            d = np.diff(c, axis=0)
            ln = np.hypot(d[:, 0], d[:, 1])
            ok = ln > 0.5
            mid = (c[:-1] + c[1:])[ok] / 2
            nrm = np.column_stack([-d[ok, 1], d[ok, 0]]) / ln[ok, None]
            pts_l.append(mid + nrm * 0.4)
            pts_r.append(mid - nrm * 0.4)
    pl = shapely.points(np.vstack(pts_l))
    pr = shapely.points(np.vstack(pts_r))
    tree = shapely.STRtree(pieces)
    vote = np.zeros(len(pieces))
    il = tree.query(pl, predicate="within")
    ir = tree.query(pr, predicate="within")
    np.add.at(vote, il[1], 1)
    np.add.at(vote, ir[1], -1)
    land = [pc for pc, v in zip(pieces, vote) if v >= 0]
    log(f"  kara: {len(pieces)} parçadan {len(land)} kara")
    return shapely.union_all(land)


# ---------------------------------------------------------------------------
# Yükselti (Copernicus GLO-30)
# ---------------------------------------------------------------------------


class Dem:
    def __init__(self, cache, extent, max_level=4):
        import rasterio
        w, s, e, n = extent
        step = 1 / 3600
        lat_top = math.ceil(n * 3600) / 3600
        lon_left = math.floor(w * 3600) / 3600
        rows = int(round((lat_top - math.floor(s * 3600) / 3600) * 3600)) + 1
        cols = int(round((math.ceil(e * 3600) / 3600 - lon_left) * 3600)) + 1
        a = np.zeros((rows, cols), np.float32)
        for la in range(math.floor(s), math.floor(n) + 1):
            for lo in range(math.floor(w), math.floor(e) + 1):
                url = DEM_URL.format(ns="N" if la >= 0 else "S", lat=abs(la),
                                     ew="E" if lo >= 0 else "W", lon=abs(lo))
                f = download(url, os.path.join(cache, "dem", os.path.basename(url)), missing_ok=True)
                if not f:
                    continue
                with rasterio.open(f) as ds:
                    t = ds.read(1).astype(np.float32)
                    # piksel merkezleri: üst sol = (la+1, lo), adım 1"
                assert t.shape == (3600, 3600), (f, t.shape)
                r0 = int(round((lat_top - (la + 1)) * 3600))
                c0 = int(round((lo - lon_left) * 3600))
                rr0, cc0 = max(r0, 0), max(c0, 0)
                rr1, cc1 = min(r0 + 3600, rows), min(c0 + 3600, cols)
                if rr1 > rr0 and cc1 > cc0:
                    a[rr0:rr1, cc0:cc1] = t[rr0 - r0:rr1 - r0, cc0 - c0:cc1 - c0]
        np.maximum(a, 0, out=a)
        log(f"  DEM {a.shape} en yüksek {a.max():.0f} m")
        sm = ndimage.gaussian_filter(a, 1.0)       # DSM (ağaç/yapı) gürültüsünü bastır
        self.levels = [(sm, lat_top, lon_left, step)]
        cur, t, l, st = sm, lat_top, lon_left, step
        for _ in range(max_level):
            h, w2 = cur.shape[0] // 2 * 2, cur.shape[1] // 2 * 2
            cur = cur[:h, :w2].reshape(h // 2, 2, w2 // 2, 2).mean(axis=(1, 3))
            t, l, st = t - st / 2, l + st / 2, st * 2
            self.levels.append((cur, t, l, st))

    def level_for(self, ground_m):
        lv = int(math.floor(math.log2(max(ground_m, 1) / 30.0)))
        return min(max(lv, 0), len(self.levels) - 1)

    def sample(self, level, lats, lons):
        """lats azalan, lons artan 1B diziler -> (len(lats), len(lons)) ızgara (bikübik)."""
        a, lat_top, lon_left, st = self.levels[level]
        fi = (lat_top - lats) / st
        fj = (lons - lon_left) / st
        i0 = max(int(math.floor(fi.min())) - 3, 0)
        i1 = min(int(math.ceil(fi.max())) + 4, a.shape[0])
        j0 = max(int(math.floor(fj.min())) - 3, 0)
        j1 = min(int(math.ceil(fj.max())) + 4, a.shape[1])
        if i1 - i0 < 5 or j1 - j0 < 5:
            return np.zeros((len(lats), len(lons)), np.float32)
        spl = RectBivariateSpline(np.arange(i0, i1), np.arange(j0, j1), a[i0:i1, j0:j1], kx=3, ky=3)
        return spl(np.clip(fi, i0, i1 - 1), np.clip(fj, j0, j1 - 1)).astype(np.float32)


class WorldCover:
    """ESA WorldCover 2021 (10 m arazi örtüsü). OSM'de çizilmemiş orman/çalılık/tarla
    alanlarını doldurur; OSM poligonları her zaman üstte çizilir."""

    def __init__(self, cache, extent):
        w, s, e, n = extent
        self.tiles = []
        for la in range(math.floor(s / 3) * 3, math.floor(n / 3) * 3 + 1, 3):
            for lo in range(math.floor(w / 3) * 3, math.floor(e / 3) * 3 + 1, 3):
                url = WC_URL.format(ns="N" if la >= 0 else "S", lat=abs(la),
                                    ew="E" if lo >= 0 else "W", lon=abs(lo))
                f = download(url, os.path.join(cache, "worldcover", os.path.basename(url)),
                             missing_ok=True)
                if f:
                    self.tiles.append((f, (lo, la, lo + 3, la + 3)))
        self.extent = extent
        self._ds = {}

    def classes(self, lats, lons, ground):
        import rasterio
        from rasterio.enums import Resampling
        from rasterio.windows import from_bounds
        out = np.zeros((len(lats), len(lons)), np.uint8)
        w, s, e, n = self.extent
        for path, (tw, ts, te, tn) in self.tiles:
            ci = np.nonzero((lons >= max(tw, w)) & (lons < min(te, e)))[0]
            ri = np.nonzero((lats > max(ts, s)) & (lats <= min(tn, n)))[0]
            if not len(ci) or not len(ri):
                continue
            key = (os.getpid(), path)
            if key not in self._ds:
                self._ds[key] = rasterio.open(path)
            ds = self._ds[key]
            lo0, lo1 = float(lons[ci[0]]), float(lons[ci[-1]])
            la1, la0 = float(lats[ri[0]]), float(lats[ri[-1]])
            win = from_bounds(lo0 - 1e-3, la0 - 1e-3, lo1 + 1e-3, la1 + 1e-3, ds.transform)
            win = win.round_offsets().round_lengths()
            f = max(1, int(ground / 16))       # yerel çözünürlük ~7-9 m; piksel başına >= 2 örnek
            shp = (max(1, int(math.ceil(win.height / f))), max(1, int(math.ceil(win.width / f))))
            data = ds.read(1, window=win, out_shape=shp, resampling=Resampling.nearest, boundless=True,
                           fill_value=0)
            t = ds.window_transform(win)
            fx = (lons[ci] - t.c) / (t.a * win.width / shp[1])
            fy = (lats[ri] - t.f) / (t.e * win.height / shp[0])
            cc = np.clip(fx.astype(int), 0, shp[1] - 1)
            rr = np.clip(fy.astype(int), 0, shp[0] - 1)
            out[np.ix_(ri, ci)] = data[np.ix_(rr, cc)]
        return out


def worldcover_paint(arr, cls, ground):
    """Sınıf ızgarasını yumuşak oylamayla düzleştirip yalnız boş kara piksellerine boyar."""
    lc = np.array([int(v * 255) for v in rgb(LAND)[:3]], np.uint8)
    empty = (arr[..., 2] == lc[0]) & (arr[..., 1] == lc[1]) & (arr[..., 0] == lc[2])
    if not empty.any():
        return
    sig = max(0.8, 12.0 / ground)
    best = np.full(cls.shape, 0.4, np.float32)
    pick = np.zeros(cls.shape, np.uint8)
    for code in WC_CLASSES:
        m = cls == code
        if not m.any():
            continue
        sm = ndimage.gaussian_filter(m.astype(np.float32), sig)
        upd = sm > best
        best[upd] = sm[upd]
        pick[upd] = code
    for code, layer in WC_CLASSES.items():
        m = empty & (pick == code)
        if m.any():
            c = rgb(FILL[layer])
            arr[m, 2], arr[m, 1], arr[m, 0] = int(c[0] * 255), int(c[1] * 255), int(c[2] * 255)


# ---------------------------------------------------------------------------
# Hazırlık: yakınlaştırma düzeyine göre süzülmüş/sadeleştirilmiş katmanlar ve etiketler
# ---------------------------------------------------------------------------
G = {}   # çatallanan (fork) işçilerle paylaşılan genel durum


def zoom_layers(z, polys, lines, tunnels, land):
    res = res_m(z)
    tol = res * 0.4 if z <= 13 else 0.0
    min_area = (2.0 * res) ** 2 if z <= 12 else 0.0
    out = {}

    def prep(geoms, area_filter=True, simplify=True):
        if not geoms:
            return None
        arr = np.array(geoms, dtype=object)
        if area_filter and min_area:
            arr = arr[shapely.area(arr) >= min_area]
        if simplify and tol:
            arr = shapely.simplify(arr, tol, preserve_topology=False)
            arr = arr[~shapely.is_empty(arr)]
        if len(arr) == 0:
            return None
        return arr, shapely.STRtree(arr)

    for k in POLY_ORDER + ["water", "military"]:
        out[k] = prep(polys[k])
    if z >= MINZOOM["building"]:
        out["building"] = prep(polys["building"], simplify=False)
    for k, v in lines.items():
        if k == "coastline" or z < MINZOOM.get(k, 99):
            continue
        out[k] = prep(v, area_filter=False)
        out["tunnel_" + k] = prep(tunnels[k], area_filter=False)
    out["land"] = prep([land], area_filter=False, simplify=True) if land is not None else None
    return out


def make_measure():
    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, 8, 8)
    return cairo.Context(surf)


def set_font(ctx, size, bold=False, italic=False):
    ctx.select_font_face(FONT, cairo.FONT_SLANT_OBLIQUE if italic else cairo.FONT_SLANT_NORMAL,
                         cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    ctx.set_font_size(size)


def place_labels(z, points, province):
    """Tüm il için tek seferde (karodan bağımsız) çakışmasız etiket yerleşimi.
    Çıktı: genel piksel koordinatlarında etiket listesi."""
    res = res_m(z)
    ctx = make_measure()
    cands = []
    for kind, name, x, y, ele, area in points:
        if kind == "peak":
            if z < PEAK[0] or (ele is None and not name):
                continue
            pri = PEAK[1] + (ele or 0) / 100
        elif kind == "water":
            if z < WATER_LABEL[0] or area / res ** 2 < 3000:
                continue
            pri = WATER_LABEL[1] + math.log10(area)
        else:
            st = PLACES[kind]
            if z < st[0]:
                continue
            pri = st[1] + min(math.log10(area + 1), 9) / 10
        if province is not None and kind not in ("city", "town") and not G["prov_label_area"].contains(
                shapely.Point(x, y)):
            continue
        cands.append((pri, kind, name, x, y, ele))
    cands.sort(key=lambda c: -c[0])
    grid = {}
    cell = 128
    placed = []
    seen = {}

    def free(b):
        x0, y0, x1, y1 = b
        for gx in range(int(x0 // cell), int(x1 // cell) + 1):
            for gy in range(int(y0 // cell), int(y1 // cell) + 1):
                for o in grid.get((gx, gy), ()):
                    if not (x1 < o[0] or o[2] < x0 or y1 < o[1] or o[3] < y0):
                        return False
        return True

    def take(b):
        x0, y0, x1, y1 = b
        for gx in range(int(x0 // cell), int(x1 // cell) + 1):
            for gy in range(int(y0 // cell), int(y1 // cell) + 1):
                grid.setdefault((gx, gy), []).append(b)

    for pri, kind, name, x, y, ele in cands:
        gx = (x + HALF) / res
        gy = (HALF - y) / res
        key = (name or "").casefold()
        if key and key in seen and any(math.hypot(gx - a, gy - b) < 300 for a, b in seen[key]):
            continue
        items = []   # (metin, boyut, kalın, eğik, renk, x, y) taban çizgisi başı
        sym = None
        if kind == "peak":
            col = PEAK[2]
            sz = 9.5 if z < 14 else 10.5
            lines_ = [t for t in (name, f"{ele:.0f} m" if ele is not None else None) if t]
            set_font(ctx, sz, bold=False, italic=False)
            ws = [ctx.text_extents(t).x_advance for t in lines_]
            lh = sz * 1.15
            x0 = gx + 6
            ytop = gy - lh * len(lines_) / 2
            for i, t in enumerate(lines_):
                items.append((t, sz if i == 0 or not name else sz - 1, False, False, col, x0,
                              ytop + lh * (i + 0.8)))
            b = (gx - 5, ytop - 2, x0 + max(ws) + 3, ytop + lh * len(lines_) + 2)
            sym = ("peak", gx, gy)
        else:
            if kind == "water":
                bold, italic, col = False, True, WATER_LABEL[2]
                sz = 10.0 if z < 13 else 11.0
            else:
                st = PLACES[kind]
                bold, italic, col = st[2], st[3], st[4]
                sz = st[5] if z <= 11 else st[6] if z == 12 else st[7]
            set_font(ctx, sz, bold, italic)
            ext = ctx.text_extents(name)
            w = ext.x_advance
            x0 = gx - w / 2
            yb = gy + sz * 0.35
            items.append((name, sz, bold, italic, col, x0, yb))
            b = (x0 - 3, yb - sz - 2, x0 + w + 3, yb + sz * 0.3 + 2)
        if not free(b):
            continue
        take(b)
        seen.setdefault(key, []).append((gx, gy))
        placed.append({"box": b, "items": items, "sym": sym})
    return placed


# ---------------------------------------------------------------------------
# Çizim
# ---------------------------------------------------------------------------


def to_px(geoms, left, top, res):
    return shapely.transform(geoms, lambda c: np.column_stack([(c[:, 0] - left) / res,
                                                               (top - c[:, 1]) / res]))


def add_path(ctx, g, close):
    for part in shapely.get_parts(g):
        if part.geom_type == "Polygon":
            rings = [part.exterior, *part.interiors]
            for r in rings:
                c = np.asarray(r.coords)
                if len(c) < 3:
                    continue
                ctx.move_to(c[0, 0], c[0, 1])
                for px, py in c[1:]:
                    ctx.line_to(px, py)
                ctx.close_path()
        elif part.geom_type in ("LineString", "LinearRing"):
            c = np.asarray(part.coords)
            if len(c) < 2:
                continue
            ctx.move_to(c[0, 0], c[0, 1])
            for px, py in c[1:]:
                ctx.line_to(px, py)
            if close:
                ctx.close_path()
        elif part.geom_type == "GeometryCollection":
            for sub in part.geoms:
                if sub.geom_type in ("Polygon", "MultiPolygon", "LineString", "MultiLineString"):
                    add_path(ctx, sub, close)


def query(layers, key, ext, view):
    """Kutuyla kesişen geometrileri kırpıp piksel koordinatına çevirir."""
    L = layers.get(key)
    if L is None:
        return []
    arr, tree = L
    idx = tree.query(box(*ext))
    if len(idx) == 0:
        return []
    g = shapely.clip_by_rect(arr[idx], *ext)
    g = g[~shapely.is_empty(g)]
    return to_px(g, *view)


def fill_layer(ctx, geoms, color):
    if len(geoms) == 0:
        return
    ctx.new_path()
    for g in geoms:
        add_path(ctx, g, True)
    ctx.set_source_rgba(*rgb(color))
    ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    ctx.fill()


def stroke_layer(ctx, geoms, color, width, dash=None, cap=cairo.LINE_CAP_ROUND, alpha=1.0):
    if len(geoms) == 0 or width <= 0:
        return
    ctx.new_path()
    for g in geoms:
        add_path(ctx, g, False)
    ctx.set_source_rgba(*(rgb(color, alpha) if isinstance(color, str) else color))
    ctx.set_line_width(width)
    ctx.set_line_cap(cap)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.set_dash(dash or [])
    ctx.stroke()
    ctx.set_dash([])


def hatch_pattern(color, spacing=8, width=1.2, alpha=0.5):
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, spacing, spacing)
    c = cairo.Context(s)
    c.set_source_rgba(*rgb(color, alpha))
    c.set_line_width(width)
    c.move_to(-1, spacing + 1)
    c.line_to(spacing + 1, -1)
    c.move_to(-1, 1)
    c.line_to(1, -1)
    c.move_to(spacing - 1, spacing + 1)
    c.line_to(spacing + 1, spacing - 1)
    c.stroke()
    p = cairo.SurfacePattern(s)
    p.set_extend(cairo.EXTEND_REPEAT)
    return p


def marsh_pattern():
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, 12, 8)
    c = cairo.Context(s)
    c.set_source_rgba(*rgb("#4a8fc0", 0.7))
    c.set_line_width(1)
    c.move_to(1, 2.5)
    c.line_to(7, 2.5)
    c.move_to(7, 6.5)
    c.line_to(12, 6.5)
    c.stroke()
    p = cairo.SurfacePattern(s)
    p.set_extend(cairo.EXTEND_REPEAT)
    return p


def surface_array(surf):
    surf.flush()
    h, stride = surf.get_height(), surf.get_stride()
    return np.ndarray((h, stride // 4, 4), np.uint8, surf.get_data())[:, :surf.get_width(), :]


def zval(table, z):
    return table[min(max(z, 8), 15) - 8]


def draw_text(ctx, text, size, bold, italic, color, x, y, halo=3.0, halo_rgba=(1, 1, 1, 0.85)):
    set_font(ctx, size, bold, italic)
    ctx.new_path()
    ctx.move_to(x, y)
    ctx.text_path(text)
    ctx.set_source_rgba(*halo_rgba)
    ctx.set_line_width(halo)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.stroke_preserve()
    ctx.set_source_rgba(*rgb(color))
    ctx.fill()


def contour_labels(ctx, paths_px, level, z, interior, taken):
    """Ana eğrilere, metakaronun kendi iç alanında kalan yükselti yazıları."""
    text = f"{level:.0f}"
    sz = 9.0 if z < 15 else 10.0
    set_font(ctx, sz)
    w = ctx.text_extents(text).x_advance
    spacing = 420 if z == 13 else 520
    ix0, iy0, ix1, iy1 = interior
    for c in paths_px:
        if len(c) < 4:
            continue
        d = np.hypot(*np.diff(c, axis=0).T)
        s = np.concatenate([[0], np.cumsum(d)])
        if s[-1] < w * 3:
            continue
        pos = 140.0
        while pos < s[-1] - w:
            a, b = pos - w / 2 - 3, pos + w / 2 + 3
            i0, i1 = np.searchsorted(s, a), np.searchsorted(s, b)
            seg = c[max(i0 - 1, 0):min(i1 + 1, len(c))]
            p0, p1 = seg[0], seg[-1]
            chord = p1 - p0
            cl = np.hypot(*chord)
            mid = (p0 + p1) / 2
            if cl > w * 0.8:
                nrm = np.array([-chord[1], chord[0]]) / cl
                dev = np.abs((seg - p0) @ nrm).max()
                bx = (mid[0] - w / 2 - 4, mid[1] - w / 2 - 4, mid[0] + w / 2 + 4, mid[1] + w / 2 + 4)
                if (dev < 2.5 and bx[0] > ix0 and bx[1] > iy0 and bx[2] < ix1 and bx[3] < iy1
                        and not any(not (bx[2] < o[0] or o[2] < bx[0] or bx[3] < o[1] or o[3] < bx[1])
                                    for o in taken)):
                    ang = math.atan2(chord[1], chord[0])
                    if ang > math.pi / 2:
                        ang -= math.pi
                    elif ang < -math.pi / 2:
                        ang += math.pi
                    ctx.save()
                    ctx.translate(mid[0], mid[1])
                    ctx.rotate(ang)
                    draw_text(ctx, text, sz, False, False, "#8a6238", -w / 2, sz * 0.35, halo=3.2,
                              halo_rgba=(0.96, 0.95, 0.91, 0.95))
                    ctx.restore()
                    taken.append(bx)
                    pos += spacing
                    continue
            pos += 40


def render_metatile(task):
    z, tiles = task
    layers = G["layers"][z]
    res = res_m(z)
    xs = [t[0] for t in tiles]
    ys = [t[1] for t in tiles]
    tx0, ty0 = min(xs), min(ys)
    W = (max(xs) - tx0 + 1) * TILE + 2 * BUF
    H = (max(ys) - ty0 + 1) * TILE + 2 * BUF
    left = -HALF + tx0 * TILE * res - BUF * res
    top = HALF - ty0 * TILE * res + BUF * res
    ext = (left, top - H * res, left + W * res, top)
    view = (left, top, res)

    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, W, H)
    ctx = cairo.Context(surf)
    ctx.set_source_rgba(*rgb(SEA))
    ctx.paint()

    # Yükselti ızgarası (piksel merkezleri)
    xc = left + (np.arange(W) + 0.5) * res
    yc = top - (np.arange(H) + 0.5) * res
    lons = np.degrees(xc / R)
    lats = inv_lat(yc)
    ground = res * math.cos(math.radians(float(lats.mean())))
    dem = G["dem"].sample(G["dem"].level_for(ground), lats, lons)

    # 1) kara
    land_px = query(layers, "land", ext, view)
    fill_layer(ctx, land_px, LAND)
    # OSM kutusu dışında kara/deniz ayrımı DEM'den (yalnız düşük yakınlıkta görünür)
    ob = G["osm_box"]
    px0, px1 = (ob[0] - left) / res, (ob[2] - left) / res
    py0, py1 = (top - ob[3]) / res, (top - ob[1]) / res
    outside = np.ones((H, W), bool)
    r0, r1 = int(max(math.ceil(py0), 0)), int(min(math.floor(py1), H))
    c0, c1 = int(max(math.ceil(px0), 0)), int(min(math.floor(px1), W))
    if r1 > r0 and c1 > c0:
        outside[r0:r1, c0:c1] = False
    if outside.any():
        arr = surface_array(surf)
        landm = outside & (dem > 0.5)
    else:
        landm = None
    if landm is not None and landm.any():
        lc = rgb(LAND)
        arr[landm, 2], arr[landm, 1], arr[landm, 0] = (int(lc[0] * 255), int(lc[1] * 255),
                                                       int(lc[2] * 255))
        surf.mark_dirty()

    if G.get("wc") is not None:
        cls = G["wc"].classes(lats, lons, ground)
        if cls.any():
            worldcover_paint(surface_array(surf), cls, ground)
            surf.mark_dirty()

    # 2) arazi örtüsü
    for k in POLY_ORDER:
        g = query(layers, k, ext, view)
        fill_layer(ctx, g, FILL[k])
        if k == "wetland" and len(g) and z >= 12:
            ctx.new_path()
            for gg in g:
                add_path(ctx, gg, True)
            ctx.set_source(marsh_pattern())
            ctx.fill()

    # 3) tepe gölgelendirmesi
    if dem.max() > 1:
        exag, sd, sh = HILLSHADE[z]
        hs_sig = HS_SMOOTH_M / ground
        dem_hs = ndimage.gaussian_filter(dem, hs_sig) if hs_sig > 0.5 else dem
        gy_, gx_ = np.gradient(dem_hs, ground)
        nx, ny = -exag * gx_, exag * gy_          # satır güneye doğru artar -> kuzey eğimi = -gy
        alt, az = math.radians(42), math.radians(315)
        lx, ly, lz = math.cos(alt) * math.sin(az), math.cos(alt) * math.cos(az), math.sin(alt)
        shade = (nx * lx + ny * ly + lz) / np.sqrt(nx * nx + ny * ny + 1) / lz
        arr = surface_array(surf)
        base = arr[..., :3].astype(np.float32)
        dark = np.clip(1 - shade, 0, 1)[..., None]
        light = np.clip(shade - 1, 0, 1)[..., None]
        out = base * (1 - sd * dark) + (255 - base) * sh * light
        arr[..., :3] = np.clip(out, 0, 255).astype(np.uint8)
        surf.mark_dirty()

    # 4) eş yükselti eğrileri
    contour_label_jobs = []
    if z in CONTOURS and dem.max() > CONTOURS[z][0]:
        step, index, labelled = CONTOURS[z]
        k = 2 if z >= 13 else 1
        sig = CONTOUR_SMOOTH_M / ground
        grid = ndimage.gaussian_filter(dem, sig)[::k, ::k] if sig > 0.5 else dem[::k, ::k]
        lv = np.arange(step, grid.max() + 1e-6, step)
        normal, idx_paths = [], []
        for level in lv:
            paths = [np.column_stack([c[:, 1] * k + 0.5 * k, c[:, 0] * k + 0.5 * k])
                     for c in find_contours(grid, level)]
            is_index = index and abs(level % index) < 1e-6
            (idx_paths if is_index else normal).extend(paths)
            if is_index and labelled:
                contour_label_jobs.append((level, paths))
        alpha = 0.55 if z >= 13 else 0.45 if z == 12 else 0.35
        for paths, width, a in ((normal, 0.6 if z < 13 else 0.8, alpha),
                                (idx_paths, 1.0 if z < 13 else 1.3, min(alpha + 0.25, 0.85))):
            if not paths:
                continue
            ctx.new_path()
            for c in paths:
                ctx.move_to(*c[0])
                for px, py in c[1:]:
                    ctx.line_to(px, py)
            ctx.set_source_rgba(*CONTOUR, a)
            ctx.set_line_width(width)
            ctx.set_line_join(cairo.LINE_JOIN_ROUND)
            ctx.stroke()

    # 5) su
    fill_layer(ctx, query(layers, "water", ext, view), WATER)
    for key, (col, widths) in (("river", RIVER), ("stream", STREAM)):
        w = zval(widths, z)
        stroke_layer(ctx, query(layers, key, ext, view), col, w)
        stroke_layer(ctx, query(layers, "tunnel_" + key, ext, view), col, w, dash=[3, 3], alpha=0.6)
    if z >= MINZOOM["spring"]:
        for sx, sy, _ in G["springs_tree"].get(ext):
            px, py = (sx - left) / res, (top - sy) / res
            ctx.new_path()
            ctx.arc(px, py, 2.6 if z < 15 else 3.2, 0, 2 * math.pi)
            ctx.set_source_rgba(*rgb("#2f7fc0"))
            ctx.fill_preserve()
            ctx.set_source_rgba(1, 1, 1, 0.9)
            ctx.set_line_width(0.9)
            ctx.stroke()

    # 6) yasak askeri alan (taralı)
    mg = query(layers, "military", ext, view)
    if len(mg):
        ctx.new_path()
        for g in mg:
            add_path(ctx, g, True)
        ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        ctx.set_source(hatch_pattern("#c0392b", spacing=8 if z >= 13 else 6))
        ctx.fill_preserve()
        ctx.set_source_rgba(*rgb("#c0392b", 0.75))
        ctx.set_line_width(1.0 if z >= 13 else 0.7)
        ctx.set_dash([4, 2])
        ctx.stroke()
        ctx.set_dash([])

    # 7) yapılar, yalar, enerji hatları
    if z >= MINZOOM["building"]:
        bg = query(layers, "building", ext, view)
        fill_layer(ctx, bg, BUILDING[0])
        stroke_layer(ctx, [shapely.boundary(g) for g in bg], BUILDING[1], 0.5)
    stroke_layer(ctx, query(layers, "cliff", ext, view), CLIFF, 1.4 if z >= 14 else 1.0)
    stroke_layer(ctx, query(layers, "power", ext, view), POWER, 0.7 if z < 15 else 0.9, alpha=0.9)

    # 8) yollar: patika ve tarla/orman yolları altta, sonra kılıflar, sonra dolgular
    wt = zval(TRACK[1], z)
    stroke_layer(ctx, query(layers, "track", ext, view), TRACK[0], wt,
                 dash=[6, 3] if z >= 13 else [4, 2], cap=cairo.LINE_CAP_BUTT)
    stroke_layer(ctx, query(layers, "path", ext, view), PATH[0], zval(PATH[1], z),
                 dash=[0.1, 2.6], cap=cairo.LINE_CAP_ROUND)
    road_geoms = {k: query(layers, k, ext, view) for k in ROAD_ORDER}
    tunnel_geoms = {k: query(layers, "tunnel_" + k, ext, view) for k in ROAD_ORDER}
    for k in ROAD_ORDER:
        fill, case, low, widths = ROADS[k]
        w = zval(widths, z)
        stroke_layer(ctx, tunnel_geoms[k], case, w, dash=[3, 2], alpha=0.5)
    for k in ROAD_ORDER:
        fill, case, low, widths = ROADS[k]
        w = zval(widths, z)
        if z >= CASING_FROM[k]:
            cw = 0.6 if z < 13 else 0.8
            stroke_layer(ctx, road_geoms[k], case, w + 2 * cw)
    for k in ROAD_ORDER:
        fill, case, low, widths = ROADS[k]
        w = zval(widths, z)
        stroke_layer(ctx, road_geoms[k], fill if z >= CASING_FROM[k] else low, w)
    rg = query(layers, "rail", ext, view)
    if z >= 13:
        stroke_layer(ctx, rg, RAIL, 2.6, cap=cairo.LINE_CAP_BUTT)
        stroke_layer(ctx, rg, "#ffffff", 1.2, dash=[7, 7], cap=cairo.LINE_CAP_BUTT)
    else:
        stroke_layer(ctx, rg, RAIL, 0.8 if z < 11 else 1.2)

    # 9) il dışı soluk örtü + il sınırı
    prov = G["province"]
    if prov is not None:
        # Örtü yalnız il dışındaki KARAYA uygulanır (ilin denizdeki idari alanı belli olmasın)
        pg = to_px(shapely.clip_by_rect(prov, *ext), *view)
        mask = cairo.ImageSurface(cairo.FORMAT_A8, W, H)
        mc = cairo.Context(mask)
        mc.new_path()
        for g in land_px:
            add_path(mc, g, True)
        mc.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        mc.fill()
        if not pg.is_empty:
            mc.new_path()
            add_path(mc, pg, True)
            mc.set_operator(cairo.OPERATOR_CLEAR)
            mc.fill()
        mask.flush()
        ma = np.ndarray((H, mask.get_stride()), np.uint8, mask.get_data())[:, :W].astype(np.float32)
        if landm is not None and landm.any():
            ma[landm] = 255.0
            ma[landm & province_px_mask(pg, W, H)] = 0.0
        a_ = (ma / 255.0 * 0.5)[..., None]
        if a_.max() > 0:
            arr = surface_array(surf)
            arr[..., :3] = (arr[..., :3] * (1 - a_) + 247.0 * a_).astype(np.uint8)
            surf.mark_dirty()
        bl = G["prov_line"]
        if bl is not None:
            bpx = to_px(shapely.clip_by_rect(bl, *ext), *view)
            if not bpx.is_empty:
                stroke_layer(ctx, [bpx], PROVINCE_LINE, 3.5 if z >= 12 else 2.4, alpha=0.25)
                stroke_layer(ctx, [bpx], PROVINCE_LINE, 1.2 if z >= 12 else 0.9, dash=[6, 3],
                             cap=cairo.LINE_CAP_BUTT, alpha=0.8)

    # 10) yazılar: eğri yükseltileri (metakaro içi), yer adları (genel yerleşim)
    gl, gt = left / res + HALF / res, HALF / res - top / res   # metakaronun genel piksel kökü
    interior = (BUF, BUF, W - BUF, H - BUF)
    taken = []
    labels = [lb for lb in G["labels"][z]
              if not (lb["box"][2] < gl or lb["box"][0] > gl + W or
                      lb["box"][3] < gt or lb["box"][1] > gt + H)]
    for lb in labels:   # yer adlarının üstüne eğri yazısı gelmesin
        b = lb["box"]
        taken.append((b[0] - gl, b[1] - gt, b[2] - gl, b[3] - gt))
    for level, paths in contour_label_jobs:
        contour_labels(ctx, paths, level, z, interior, taken)
    for lb in labels:
        if lb["sym"]:
            _, sx, sy = lb["sym"]
            sx, sy = sx - gl, sy - gt
            ctx.new_path()
            ctx.move_to(sx, sy - 4.2)
            ctx.line_to(sx + 4.2, sy + 3.2)
            ctx.line_to(sx - 4.2, sy + 3.2)
            ctx.close_path()
            ctx.set_source_rgba(1, 1, 1, 0.9)
            ctx.set_line_width(2)
            ctx.stroke_preserve()
            ctx.set_source_rgba(*rgb(PEAK[2]))
            ctx.fill()
        for text, size, bold, italic, col, x, y in lb["items"]:
            draw_text(ctx, text, size, bold, italic, col, x - gl, y - gt)

    # Kes ve kodla
    arr = surface_array(surf)
    img = np.ascontiguousarray(arr[..., 2::-1])   # BGRX -> RGB
    out = []
    for x, y in tiles:
        ox = (x - tx0) * TILE + BUF
        oy = (y - ty0) * TILE + BUF
        out.append((z, x, y, encode(img[oy:oy + TILE, ox:ox + TILE], G["jpeg_quality"])))
    return out


def province_px_mask(pg, W, H):
    surf = cairo.ImageSurface(cairo.FORMAT_A8, W, H)
    if not pg.is_empty:
        c = cairo.Context(surf)
        add_path(c, pg, True)
        c.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        c.fill()
    surf.flush()
    return np.ndarray((H, surf.get_stride()), np.uint8, surf.get_data())[:, :W] > 127


def encode(rgb_tile, quality):
    flat = rgb_tile.reshape(-1, 3).astype(np.uint32)
    packed = flat[:, 0] << 16 | flat[:, 1] << 8 | flat[:, 2]
    u, inv = np.unique(packed, return_inverse=True)
    if len(u) <= 256:      # kayıpsız paletli PNG (renkler zaten <= 256)
        im = Image.fromarray(inv.reshape(TILE, TILE).astype(np.uint8), "P")
        pal = np.column_stack([u >> 16 & 255, u >> 8 & 255, u & 255]).astype(np.uint8)
        im.putpalette(pal.ravel().tolist())
        buf = io.BytesIO()
        im.save(buf, "PNG", optimize=True)
        return buf.getvalue()
    buf = io.BytesIO()
    Image.fromarray(rgb_tile, "RGB").save(buf, "JPEG", quality=quality, optimize=True,
                                          subsampling="4:2:0")
    return buf.getvalue()


class PointIndex:
    def __init__(self, pts):
        self.pts = pts
        self.arr = np.array([(p[0], p[1]) for p in pts]) if pts else np.zeros((0, 2))

    def get(self, ext):
        if not len(self.arr):
            return []
        m = ((self.arr[:, 0] >= ext[0]) & (self.arr[:, 0] <= ext[2]) &
             (self.arr[:, 1] >= ext[1]) & (self.arr[:, 1] <= ext[3]))
        return [self.pts[i] for i in np.nonzero(m)[0]]


# ---------------------------------------------------------------------------
# Karo seçimi
# ---------------------------------------------------------------------------


def select_tiles(z, area, land):
    """İl alanıyla kesişen ve kara içeren karolar."""
    w, s, e, n = shapely.bounds(area)
    res = res_m(z)
    s_ = TILE * res
    x0, x1 = int((w + HALF) // s_), int((e + HALF) // s_)
    y0, y1 = int((HALF - n) // s_), int((HALF - s) // s_)
    xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
    xs, ys = xs.ravel(), ys.ravel()
    boxes = shapely.box(-HALF + xs * s_, HALF - (ys + 1) * s_, -HALF + (xs + 1) * s_, HALF - ys * s_)
    keep = shapely.intersects(area, boxes) & shapely.intersects(land, boxes)
    return list(zip(xs[keep].tolist(), ys[keep].tolist()))


def contact_sheet(pack_tiles, out_dir, zooms):
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    for z in zooms:
        ts = {(x, y): d for (zz, x, y), d in pack_tiles.items() if zz == z}
        if not ts:
            continue
        xs = [k[0] for k in ts]
        ys = [k[1] for k in ts]
        # en çok 6x4 karo: ortadaki bölge
        cx, cy = (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2
        nx, ny = min(6, max(xs) - min(xs) + 1), min(4, max(ys) - min(ys) + 1)
        ax, ay = max(min(xs), cx - nx // 2), max(min(ys), cy - ny // 2)
        mos = Image.new("RGB", (nx * TILE, ny * TILE), SEA)
        for (x, y), d in ts.items():
            if ax <= x < ax + nx and ay <= y < ay + ny:
                mos.paste(Image.open(io.BytesIO(d)).convert("RGB"), ((x - ax) * TILE, (y - ay) * TILE))
        p = os.path.join(out_dir, f"mozaik_z{z}.png")
        mos.save(p)
        paths.append(p)
        # birkaç tekil karo
        for i, (x, y) in enumerate(sorted(ts)[:: max(1, len(ts) // 3)][:3]):
            d = ts[(x, y)]
            ext = "jpg" if d[:2] == b"\xff\xd8" else "png"
            with open(os.path.join(out_dir, f"karo_{z}_{x}_{y}.{ext}"), "wb") as fh:
                fh.write(d)
    # kontak tabakası: her yakınlık için mozaiğin küçültülmemiş ilk 3x2 karosu yan yana
    thumbs = [Image.open(p) for p in paths]
    if thumbs:
        cw = 3 * TILE
        chh = 2 * TILE
        sheet = Image.new("RGB", (cw * min(3, len(thumbs)), (chh + 24) * math.ceil(len(thumbs) / 3)),
                          "white")
        from PIL import ImageDraw
        dr = ImageDraw.Draw(sheet)
        for i, (t, p) in enumerate(zip(thumbs, paths)):
            cx, cy = (i % 3) * cw, (i // 3) * (chh + 24)
            sheet.paste(t.crop((0, 0, min(cw, t.width), min(chh, t.height))), (cx, cy + 24))
            dr.text((cx + 6, cy + 5), os.path.basename(p), fill="black")
        sp = os.path.join(out_dir, "kontak_tabakasi.png")
        sheet.save(sp)
        paths.append(sp)
    return paths


# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------


def parse_pack(s):
    name, zr = s.split(":")
    a, b = zr.split("-")
    return name, int(a), int(b)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--osm", required=True, help=".osm.pbf (ör. Geofabrik turkey-latest) ya da .osm")
    ap.add_argument("--bbox", default=",".join(map(str, PROVINCE_BBOX)), help="w,s,e,n (derece)")
    ap.add_argument("--no-province", action="store_true",
                    help="il sınırı arama; kutunun tamamını çiz (küçük denemeler için)")
    ap.add_argument("--cache", default="veri/basemap", help="indirme/ara dosya klasörü")
    ap.add_argument("--out", default="cikti")
    ap.add_argument("--pack", action="append", type=parse_pack,
                    help="ad:zmin-zmax (birden çok verilebilir)")
    ap.add_argument("--jpeg-quality", type=int, default=78)
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--url-base", default="https://github.com/oguzbay-del/av-harita-veri/releases/download/basemap-istanbul")
    ap.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--no-worldcover", action="store_true",
                    help="ESA WorldCover arazi örtüsünü kullanma (yalnız OSM)")
    ap.add_argument("--samples", help="örnek PNG/JPEG ve kontak tabakası klasörü")
    a = ap.parse_args()
    packs = a.pack or [("istanbul_topo_low", 8, 12), ("istanbul_topo_high", 13, 15)]
    bbox = tuple(float(v) for v in a.bbox.split(","))
    t0 = time.time()

    margin = 0.0 if a.no_province else OSM_MARGIN
    obox = (bbox[0] - margin, bbox[1] - margin, bbox[2] + margin, bbox[3] + margin)
    log("OSM hazırlanıyor")
    gj, prov_gj = osm_prepare(a.osm, obox, os.path.join(a.cache, "osm"), not a.no_province)
    polys, lines, tunnels, points, springs = load_osm(gj)
    ox0, oy0 = merc_xy(obox[0], obox[1])
    ox1, oy1 = merc_xy(obox[2], obox[3])
    frame = box(float(ox0), float(oy0), float(ox1), float(oy1))
    G["osm_box"] = (float(ox0), float(oy0), float(ox1), float(oy1))
    log("Kara poligonu")
    land = build_land(lines["coastline"], frame)
    if a.no_province:
        bx0, by0 = merc_xy(bbox[0], bbox[1])
        bx1, by1 = merc_xy(bbox[2], bbox[3])
        area = box(float(bx0), float(by0), float(bx1), float(by1))
        G["province"] = None
        G["prov_line"] = None
        G["prov_label_area"] = area
    else:
        prov = load_province(prov_gj)
        log(f"  il alanı {prov.area / 1e6:.0f} km² (Mercator), kara ile kesişim hesaplanıyor")
        area = prov
        G["province"] = shapely.simplify(prov, 2.0)
        # il sınırının yalnız karadaki kısmı çizilir (denizdeki idari çizgi gösterilmez)
        G["prov_line"] = shapely.intersection(G["province"].boundary, land.buffer(50))
        G["prov_label_area"] = prov.buffer(1500)
    shapely.prepare(area)
    shapely.prepare(land)
    shapely.prepare(G["prov_label_area"])

    zooms = sorted({z for _, z0, z1 in packs for z in range(z0, z1 + 1)})
    tiles_by_z = {z: select_tiles(z, area, land) for z in zooms}
    for z in zooms:
        log(f"  z{z}: {len(tiles_by_z[z])} karo")

    # DEM: çizilecek tüm karoların kapsamı
    exts = []
    for z, ts in tiles_by_z.items():
        if ts:
            xs = [t[0] for t in ts]
            ys = [t[1] for t in ts]
            n = 2 ** z
            pad = BUF / TILE
            lon0 = (min(xs) - pad) / n * 360 - 180
            lon1 = (max(xs) + 1 + pad) / n * 360 - 180
            lat1 = float(inv_lat(HALF - (min(ys) - pad) / n * WORLD))
            lat0 = float(inv_lat(HALF - (max(ys) + 1 + pad) / n * WORLD))
            exts.append((lon0, lat0, lon1, lat1))
    dext = (min(e[0] for e in exts), min(e[1] for e in exts),
            max(e[2] for e in exts), max(e[3] for e in exts))
    log(f"DEM yükleniyor {tuple(round(v, 3) for v in dext)}")
    G["dem"] = Dem(a.cache, dext)
    G["wc"] = None if a.no_worldcover else WorldCover(a.cache, obox)
    G["springs_tree"] = PointIndex(springs)
    G["jpeg_quality"] = a.jpeg_quality

    os.makedirs(a.out, exist_ok=True)
    manifest_files = []
    all_tiles = {}
    ctx = multiprocessing.get_context("fork")
    for name, z0, z1 in packs:
        log(f"{name}: katmanlar ve etiketler hazırlanıyor")
        pz = range(z0, z1 + 1)
        G["layers"] = {z: zoom_layers(z, polys, lines, tunnels, land) for z in pz}
        G["labels"] = {z: place_labels(z, points, G["province"]) for z in pz}
        for z in pz:
            log(f"  z{z}: {len(G['labels'][z])} etiket")
        tasks = []
        for z in range(z0, z1 + 1):
            groups = {}
            for x, y in tiles_by_z[z]:
                groups.setdefault((x // META, y // META), []).append((x, y))
            tasks += [(z, g) for g in groups.values()]
        tasks.sort(key=lambda t: -len(t[1]))
        log(f"{name}: z{z0}-{z1}, {sum(len(t[1]) for t in tasks)} karo, {len(tasks)} metakaro")
        res_tiles = []
        done = 0
        with ctx.Pool(a.workers) as pool:
            for out in pool.imap_unordered(render_metatile, tasks):
                res_tiles += out
                done += 1
                if done % max(1, len(tasks) // 20) == 0 or done == len(tasks):
                    mb = sum(len(t[3]) for t in res_tiles) / 1e6
                    log(f"  {done}/{len(tasks)} metakaro, {len(res_tiles)} karo, {mb:.1f} MB")
        path = os.path.join(a.out, f"{name}.avtp")
        write_pack(path, res_tiles)
        size = os.path.getsize(path)
        per_z = {}
        for z, x, y, d in res_tiles:
            c = per_z.setdefault(z, [0, 0, 0])
            c[0] += 1
            c[1] += len(d)
            c[2] += d[:2] == b"\xff\xd8"
        for z in sorted(per_z):
            c = per_z[z]
            log(f"  z{z}: {c[0]} karo, {c[1] / 1e6:.2f} MB, JPEG {c[2]}, PNG {c[0] - c[2]}, "
                f"ort {c[1] / max(c[0], 1) / 1024:.1f} KB")
        log(f"  {path}: {size / 1e6:.2f} MB")
        manifest_files.append({"name": f"{name}.avtp", "minZoom": z0, "maxZoom": z1, "bytes": size,
                               "sha256": sha256(path), "url": f"{a.url_base}/{name}.avtp",
                               "tiles": len(res_tiles)})
        for z, x, y, d in res_tiles:
            all_tiles[(z, x, y)] = d

    w, s, e, n = bbox
    manifest = {
        "version": a.version,
        "attribution": ATTRIBUTION_TR + ("" if a.no_worldcover else WC_ATTR_TR),
        "attributionEn": ATTRIBUTION_EN + ("" if a.no_worldcover else WC_ATTR_EN),
        "tileSize": TILE,
        "bounds": [w, s, e, n],
        "missingTileColor": MANIFEST_SEA_COLOR,
        "files": manifest_files,
    }
    mp = os.path.join(a.out, "basemap_manifest.json")
    with open(mp, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    log(f"{mp} yazıldı; toplam {time.time() - t0:.0f} s")
    if a.samples:
        for p in contact_sheet(all_tiles, a.samples, zooms):
            log(f"  örnek: {p}")


if __name__ == "__main__":
    main()
