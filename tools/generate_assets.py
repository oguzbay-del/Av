#!/usr/bin/env python3
"""
GeoPDF avlak haritasından iOS uygulaması için veri üretir.

Tarım ve Orman Bakanlığı'nın yayınladığı il avlak haritaları (ArcMap çıktısı)
ISO 32000 "geospatial PDF" formatındadır: sayfada köşe koordinatları (WGS84)
gömülüdür. Bu araç:

  1. Gömülü koordinat referansını (/VP -> /Measure -> /GPTS) okur,
  2. Harita alanını lejant renklerine göre sınıflandırıp bölge ızgarası
     (<ad>.zones.bin, her bayt bir sınıf kimliği, ham DEFLATE) üretir,
  3. Haritayı Web Mercator karolarına (<ad>.tiles, tek dosyada paketlenmiş PNG)
     dönüştürür,
  4. Uygulamanın okuyacağı <ad>.json meta verisini yazar.

Kullanım:
  pip install pymupdf numpy scipy pillow
  python3 tools/generate_assets.py maps/34_istanbul_2024_2025.pdf \
      --name istanbul_2024_2025 --title "İstanbul Avlaklar Haritası" \
      --season "2024-2025" --out ios/AvHaritasi/MapData

Başka bir il / sezon haritası için aynı komutu yeni PDF ile çalıştırın.
Lejant renkleri farklıysa CLASSES tablosunu güncelleyin ve
--preview ile çıktıyı mutlaka gözle kontrol edin.
"""
import argparse
import io
import json
import math
import re
import struct
import sys
import zlib

import numpy as np
import pymupdf
from PIL import Image
from scipy import ndimage

# ---------------------------------------------------------------------------
# Sınıflar. status: "yasak" | "dikkat" | "izinli" | "disarida"
# colors: haritadaki (lejanttaki) dolgu renkleri, RGB 0-255.
# ---------------------------------------------------------------------------
OUTSIDE = 0
CLASSES = [
    dict(id=0, key="disarida", name="Harita dışı / deniz", status="disarida",
         colors=[], description="Bu nokta haritada bir avlak alanı olarak işaretlenmemiş (deniz, harita dışı ya da veri yok)."),
    dict(id=1, key="devlet_avlagi", name="Devlet Avlağı", status="izinli",
         colors=[(255, 235, 190)], description="Av; avcılık belgesi, avlanma izin kartı ve Merkez Av Komisyonu kararındaki gün, tür ve kotalara uyulması şartıyla yapılabilir."),
    dict(id=2, key="genel_avlak", name="Genel Avlak", status="izinli",
         colors=[(225, 225, 225)], description="Av; avcılık belgesi ve Merkez Av Komisyonu kararındaki gün, tür ve kotalara uyulması şartıyla yapılabilir."),
    dict(id=3, key="korunan_alan", name="Özel Kanunlarla Korunan Alan", status="yasak",
         colors=[(115, 178, 115), (128, 192, 160), (120, 184, 140)],
         description="Milli park, tabiat parkı, yaban hayatı geliştirme sahası vb. Özel kanunlarla korunan alanlarda avlanma yasaktır."),
    dict(id=4, key="ava_yasak", name="Ava Yasak Alan", status="yasak",
         colors=[(255, 0, 0), (132, 0, 164)],
         description="Bu alanda avlanmak yasaktır."),
    dict(id=5, key="yaban_hayvani_yerlestirme", name="Yaban Hayvanı Yerleştirme Sahası", status="yasak",
         colors=[(255, 255, 0)], scan_colors=[(252, 252, 115)], description="Yaban hayvanı yerleştirme sahalarında avlanmak yasaktır."),
    dict(id=6, key="ornek_avlak", name="Örnek Avlak", status="dikkat",
         colors=[(204, 204, 204), (222, 113, 255)],
         description="Örnek avlaklarda av yalnızca özel izin / kota (av turizmi) ile yapılabilir. İzniniz yoksa avlanmayın."),
    dict(id=7, key="gol", name="Göl / Baraj", status="dikkat",
         colors=[(151, 219, 242)], description="Su yüzeyi. Baraj ve içme suyu havzalarında ek yasaklar olabilir."),
]

# Haritada alan dolgusu olmayan ama sık geçen renkler (yazı, yol, sınır vb.):
# bunlar "gürültü" sayılır ve en yakın alan sınıfıyla doldurulur.
COLOR_TOLERANCE = 18          # RGB öklid mesafesi
SCAN_COLOR_TOLERANCE = 34     # JPEG taramalarda renkler daha dağınık
WHITE_MIN = 245               # bu değerin üstü beyaz kabul edilir


def parse_geopdf(doc, page):
    """Sayfanın /VP sözlüğünden BBox ve köşe koordinatlarını okur."""
    pobj = doc.xref_object(page.xref)
    m = re.search(r"/BBox\s*\[\s*([-\d.\s]+)\]", pobj)
    meas = re.search(r"/Measure\s+(\d+)\s+0\s+R", pobj)
    if not m or not meas:
        sys.exit("Bu PDF'te gömülü koordinat referansı (/VP /Measure) bulunamadı.")
    bbox = [float(v) for v in m.group(1).split()]
    mobj = doc.xref_object(int(meas.group(1)))
    nums = lambda key: [float(v) for v in re.search(key + r"\s*\[\s*([-\d.\s]+)\]", mobj).group(1).split()]
    gpts = nums("/GPTS")    # lat lon çiftleri
    lpts = nums("/LPTS")    # birim kare içinde x y çiftleri
    if "WGS" not in "".join(doc.xref_object(x) for x in range(1, doc.xref_length())
                              if "GEOGCS" in doc.xref_object(x)):
        print("UYARI: GCS WGS84 değil gibi görünüyor, sonuçları kontrol edin.", file=sys.stderr)
    return bbox, gpts, lpts


def homography(src, dst):
    """4 nokta eşlemesinden 3x3 projektif dönüşüm (src -> dst)."""
    A, b = [], []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    h = np.linalg.solve(np.array(A, float), np.array(b, float))
    return np.append(h, 1.0).reshape(3, 3)


def apply_h(H, x, y):
    w = H[2, 0] * x + H[2, 1] * y + H[2, 2]
    return (H[0, 0] * x + H[0, 1] * y + H[0, 2]) / w, (H[1, 0] * x + H[1, 1] * y + H[1, 2]) / w


def render(page, clip, scale):
    pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), clip=clip, alpha=False)
    return np.frombuffer(pix.samples, np.uint8).reshape(pix.h, pix.w, 3)


def disk(r):
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def raster_only_page(pdf_path):
    """Yazıları ve vektör çizimleri (yol, ilçe sınırı, köy işaretleri...) silinmiş
    sayfa. Bakanlık haritalarında alan dolguları rasterdır; böylece sınıflandırma
    yalnızca alan renklerini görür."""
    doc = pymupdf.open(pdf_path)
    page = doc[0]
    page.add_redact_annot(page.rect)
    page.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_NONE,
                          graphics=pymupdf.PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED,
                          text=pymupdf.PDF_REDACT_TEXT_REMOVE)
    return doc, page


def remove_specks(cls, cid, min_area):
    m = cls == cid
    lab, n = ndimage.label(m)
    if n:
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        cls[m & np.isin(lab, 1 + np.nonzero(sizes < min_area)[0])] = 255


def open_filter(cls, cid, radius, min_area):
    """Sınıfı morfolojik açma + alan eşiğiyle süzer: ince çizgiler (ilçe sınırı,
    yollar) ve küçük işaretler (köy merkezi) alan olarak sayılmaz."""
    m = cls == cid
    if not m.any():
        return
    opened = ndimage.binary_opening(m, structure=disk(radius))
    lab, n = ndimage.label(opened)
    keep = np.zeros_like(m)
    if n:
        sizes = ndimage.sum(opened, lab, range(1, n + 1))
        keep = np.isin(lab, 1 + np.nonzero(sizes >= min_area)[0])
    cls[m & ~keep] = 255


def classify(img, mask_boxes_px, px_per_pt, scan=False):
    h, w, _ = img.shape
    f = img.astype(np.int32)
    cls = np.full((h, w), 255, np.uint8)        # 255 = gürültü / belirsiz
    tol = SCAN_COLOR_TOLERANCE if scan else COLOR_TOLERANCE
    for c in CLASSES:
        for col in c["colors"] + (c.get("scan_colors", []) if scan else []):
            d2 = ((f - np.array(col)) ** 2).sum(axis=2)
            cls[(d2 <= tol ** 2) & (cls == 255)] = c["id"]

    white = (img.min(axis=2) >= WHITE_MIN) & (cls == 255)
    if scan:
        # Taramada yazılar, yollar ve işaretler alan renginin üstüne basılı:
        # ince kırmızı/mor çizgileri ve köy işaretlerini ayıkla, yazı halelerini
        # (beyaz) deniz sayma.
        open_filter(cls, 4, max(2, round(1.2 * px_per_pt)), (4 * px_per_pt) ** 2)
        for cid in (1, 2, 3, 5, 6, 7):
            # yazı kenarlarındaki gri pikseller "genel avlak", dereler "göl" sanılmasın
            open_filter(cls, cid, max(1, round(0.8 * px_per_pt)), (3 * px_per_pt) ** 2)
        wo = ndimage.binary_opening(white, structure=disk(max(2, round(2.0 * px_per_pt))))
        lab, n = ndimage.label(wo)
        big = np.zeros_like(white)
        if n:
            sizes = ndimage.sum(wo, lab, range(1, n + 1))
            big = np.isin(lab, 1 + np.nonzero(sizes >= (25 * px_per_pt) ** 2)[0])
        cls[ndimage.binary_propagation(big, mask=white)] = OUTSIDE
    else:
        # Deniz / harita dışı (küçük beyaz lekeler gürültü sayılır).
        cls[white] = OUTSIDE
        for c in CLASSES:
            remove_specks(cls, c["id"], (1.5 * px_per_pt) ** 2)

    # Lejant / bilgi kutuları: tamamen harita dışı.
    for (x0, y0, x1, y1) in mask_boxes_px:
        cls[max(0, y0):max(0, y1), max(0, x0):max(0, x1)] = OUTSIDE

    # Gürültüyü (avlak sınır çizgileri vb.) en yakın sınıflandırılmış pikselle doldur.
    noise = cls == 255
    _, (iy, ix) = ndimage.distance_transform_edt(noise, return_indices=True)
    return cls[iy, ix]


def mercator_tile_bounds(z, x, y):
    n = 2 ** z
    lon0 = x / n * 360 - 180
    lon1 = (x + 1) / n * 360 - 180
    lat = lambda t: math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * t / n))))
    return lon0, lat(y + 1), lon1, lat(y)   # w, s, e, n


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def build_tiles(disp, H_disp, zones, H_zone, bounds, zmin, zmax, colors):
    w_, s_, e_, n_ = bounds
    tiles = []
    for z in range(zmin, zmax + 1):
        x0, y0 = lonlat_to_tile(w_, n_, z)
        x1, y1 = lonlat_to_tile(e_, s_, z)
        n = 2 ** z
        for ty in range(int(y0), int(y1) + 1):
            # Karodaki her satırın enlemi (Mercator ters dönüşüm)
            t = ty + (np.arange(256) + 0.5) / 256
            lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * t / n))))
            for tx in range(int(x0), int(x1) + 1):
                lon = (tx + (np.arange(256) + 0.5) / 256) / n * 360 - 180
                LON, LAT = np.meshgrid(lon, lat)
                zx, zy = apply_h(H_zone, LON, LAT)
                zx = np.floor(zx).astype(int); zy = np.floor(zy).astype(int)
                inside = (zx >= 0) & (zy >= 0) & (zx < zones.shape[1]) & (zy < zones.shape[0])
                zc = np.zeros(LON.shape, np.uint8)
                zc[inside] = zones[zy[inside], zx[inside]]
                alpha = inside & (zc != OUTSIDE)
                if not alpha.any():
                    continue
                dx, dy = apply_h(H_disp, LON, LAT)
                dx = np.clip(np.floor(dx).astype(int), 0, disp.shape[1] - 1)
                dy = np.clip(np.floor(dy).astype(int), 0, disp.shape[0] - 1)
                rgba = np.zeros((256, 256, 4), np.uint8)
                rgba[..., :3] = disp[dy, dx]
                rgba[..., 3] = np.where(alpha, 255, 0)
                im = Image.fromarray(rgba, "RGBA")
                # Boyutu küçültmek için palete indir (şeffaflık korunur)
                im = im.quantize(colors=colors, method=Image.Quantize.FASTOCTREE)
                buf = io.BytesIO(); im.save(buf, "PNG", optimize=True)
                tiles.append((z, tx, ty, buf.getvalue()))
        print(f"  z{z}: toplam {len(tiles)} karo", file=sys.stderr)
    return tiles


def write_pack(path, tiles):
    # Biçim (little endian): "AVTP" | u32 sürüm=1 | u32 adet |
    #   adet x (u8 z, 3 bayt boşluk, u32 x, u32 y, u64 ofset, u32 uzunluk) | veri
    header = 12 + 24 * len(tiles)
    with open(path, "wb") as fh:
        fh.write(b"AVTP" + struct.pack("<II", 1, len(tiles)))
        off = header
        for z, x, y, data in tiles:
            fh.write(struct.pack("<B3xIIQI", z, x, y, off, len(data)))
            off += len(data)
        for *_, data in tiles:
            fh.write(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf")
    ap.add_argument("--name", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--season", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--zone-scale", type=float, default=5.0, help="bölge ızgarası çözünürlüğü (piksel/pt)")
    ap.add_argument("--display-scale", type=float, default=8.0, help="karo kaynağı çözünürlüğü (piksel/pt)")
    ap.add_argument("--min-zoom", type=int, default=8)
    ap.add_argument("--max-zoom", type=int, default=13)
    ap.add_argument("--colors", type=int, default=96, help="karo paleti renk sayısı")
    ap.add_argument("--preview", help="sınıflandırma önizleme PNG yolu")
    ap.add_argument("--scan", action="store_true",
                    help="taranmış harita (yazı ve çizgiler görüntünün içinde; bkz. georef_scan.py)")
    a = ap.parse_args()

    doc = pymupdf.open(a.pdf)
    page = doc[0]
    bbox, gpts, lpts = parse_geopdf(doc, page)
    bx0, by0, bx1, by1 = bbox
    page_h = page.rect.height
    # /VP BBox PDF koordinatında (alt-sol orijin); MuPDF üst-sol orijin kullanır.
    # LPTS (0,0) BBox'un ilk köşesine (bx0, by0) karşılık gelir.
    pt = lambda u, v: (bx0 + u * (bx1 - bx0), page_h - (by0 + v * (by1 - by0)))
    corners_pt = [pt(lpts[i], lpts[i + 1]) for i in range(0, 8, 2)]
    corners_ll = [(gpts[i + 1], gpts[i]) for i in range(0, 8, 2)]   # (lon, lat)
    xs = [c[0] for c in corners_pt]; ys = [c[1] for c in corners_pt]
    clip = pymupdf.Rect(min(xs), min(ys), max(xs), max(ys))
    lons = [c[0] for c in corners_ll]; lats = [c[1] for c in corners_ll]
    bounds = (min(lons), min(lats), max(lons), max(lats))
    print(f"Harita çerçevesi (pt): {clip}  sınırlar: {bounds}", file=sys.stderr)

    def H_for(scale):
        dst = [((x - clip.x0) * scale, (y - clip.y0) * scale) for x, y in corners_pt]
        return homography(corners_ll, dst)

    # Lejant/bilgi kutuları: harita çerçevesi içinde beyaz dolgulu büyük dikdörtgenler
    boxes = []
    for d in page.get_drawings():
        r = d["rect"]
        if (d.get("fill") == (1.0, 1.0, 1.0) and r.width * r.height > 1500
                and r.width < clip.width * 0.6 and clip.intersects(r)):
            boxes.append(r)
    print(f"Maskelenen kutu sayısı: {len(boxes)}", file=sys.stderr)

    zs = a.zone_scale
    print("Bölge ızgarası oluşturuluyor...", file=sys.stderr)
    _rdoc, rpage = raster_only_page(a.pdf)
    zimg = render(rpage, clip, zs)
    boxes_px = [(int((r.x0 - clip.x0) * zs), int((r.y0 - clip.y0) * zs),
                 int(math.ceil((r.x1 - clip.x0) * zs)), int(math.ceil((r.y1 - clip.y0) * zs))) for r in boxes]
    zones = classify(zimg, boxes_px, zs, scan=a.scan)
    H_zone = H_for(zs)
    # Ham DEFLATE (zlib başlıksız): iOS'ta NSData.decompressed(using: .zlib) ile açılır.
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(f"{a.out}/{a.name}.zones.bin", "wb") as fh:
        fh.write(comp.compress(zones.tobytes()) + comp.flush())

    if a.preview:
        pal = {0: (255, 255, 255), 1: (255, 235, 190), 2: (200, 200, 200), 3: (60, 150, 60),
               4: (255, 0, 0), 5: (240, 220, 0), 6: (170, 90, 230), 7: (100, 180, 240)}
        rgb = np.zeros(zones.shape + (3,), np.uint8)
        for k, v in pal.items():
            rgb[zones == k] = v
        Image.fromarray(rgb).save(a.preview)

    print("Karolar oluşturuluyor...", file=sys.stderr)
    ds = a.display_scale
    disp = render(page, clip, ds)
    tiles = build_tiles(disp, H_for(ds), zones, H_zone, bounds, a.min_zoom, a.max_zoom, a.colors)
    write_pack(f"{a.out}/{a.name}.tiles", tiles)

    meta = dict(
        name=a.name, title=a.title, season=a.season,
        source="T.C. Tarım ve Orman Bakanlığı – avlakharitalari.tarimorman.gov.tr",
        bounds=dict(west=bounds[0], south=bounds[1], east=bounds[2], north=bounds[3]),
        metersPerZonePixel=dict(
            x=(bounds[2] - bounds[0]) / zones.shape[1] * 111320 * math.cos(math.radians((bounds[1] + bounds[3]) / 2)),
            y=(bounds[3] - bounds[1]) / zones.shape[0] * 110540),
        zones=dict(file=f"{a.name}.zones.bin", width=int(zones.shape[1]), height=int(zones.shape[0]),
                   lonLatToPixel=[float(v) for v in H_zone.flatten()]),
        tiles=dict(file=f"{a.name}.tiles", minZoom=a.min_zoom, maxZoom=a.max_zoom),
        classes=[dict({k: v for k, v in c.items() if k not in ("colors", "scan_colors")},
                      color="#%02X%02X%02X" % (c["colors"][0] if c["colors"] else (255, 255, 255)))
                 for c in CLASSES],
    )
    with open(f"{a.out}/{a.name}.json", "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    counts = np.bincount(zones.ravel(), minlength=len(CLASSES))
    for c in CLASSES:
        print(f"  {c['name']:35s} {counts[c['id']] / zones.size * 100:6.2f}%", file=sys.stderr)
    print("Tamam.", file=sys.stderr)


if __name__ == "__main__":
    main()
