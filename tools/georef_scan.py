#!/usr/bin/env python3
"""
Taranmış (koordinat bilgisi olmayan) bir avlak haritasını, aynı şablonla basılmış
GeoPDF bir referans haritaya hizalayıp GeoPDF olarak kaydeder.

Bakanlığın 2026-2027 İstanbul haritası tek bir JPEG görüntüden oluşan bir PDF.
2024-2025 haritası ise koordinatlı bir GeoPDF. İkisi de aynı ArcMap şablonu ve
ölçekle basıldığı için kara/deniz maskeleri üzerinde afin bir eşleştirme (OpenCV
ECC) yapılıyor. Sonra referansın köşe koordinatları yeni sayfaya aktarılıyor.

  pip install pymupdf numpy opencv-python-headless
  python3 tools/georef_scan.py maps/34_istanbul_2024_2025.pdf "34 27.pdf" \
      maps/34_istanbul_2026_2027.pdf --check docs/hizalama_kontrol.png

Çıktı PDF'i `generate_assets.py --scan` ile işlenebilir.
"""
import argparse
import re
import sys

import cv2
import numpy as np
import pymupdf

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from generate_assets import parse_geopdf  # noqa: E402

SCALE = 2.0   # hizalama çözünürlüğü (piksel/pt)


def render(page):
    pix = page.get_pixmap(matrix=pymupdf.Matrix(SCALE, SCALE), alpha=False)
    return np.frombuffer(pix.samples, np.uint8).reshape(pix.h, pix.w, 3)


def landmask(a):
    return cv2.GaussianBlur((a.min(axis=2) < 235).astype(np.float32), (0, 0), 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("scan")
    ap.add_argument("out")
    ap.add_argument("--check", help="hizalama kontrol görüntüsü (yarı saydam üst üste)")
    a = ap.parse_args()

    rdoc = pymupdf.open(a.reference)
    rpage = rdoc[0]
    sdoc = pymupdf.open(a.scan)
    spage = sdoc[0]

    ref = render(rpage)
    scn = render(spage)
    h = min(ref.shape[0], scn.shape[0]); w = min(ref.shape[1], scn.shape[1])
    ref, scn = ref[:h, :w], scn[:h, :w]

    # Referansın harita çerçevesi (lejant ve başlık hariç kalacak şekilde kırpılmış)
    bbox, gpts, lpts = parse_geopdf(rdoc, rpage)
    ph = rpage.rect.height
    bx0, by0, bx1, by1 = bbox
    pt = lambda u, v: (bx0 + u * (bx1 - bx0), ph - (by0 + v * (by1 - by0)))
    corners = [pt(lpts[i], lpts[i + 1]) for i in range(0, 8, 2)]
    xs = [c[0] for c in corners]; ys = [c[1] for c in corners]
    roi = np.zeros((h, w), np.float32)
    x0, x1 = int(min(xs) * SCALE), int(max(xs) * SCALE)
    y0, y1 = int(min(ys) * SCALE), int(max(ys) * SCALE)
    roi[y0:y1, x0:x1] = 1
    # Sağ üstteki bilgi kutuları ve sağ alttaki lejant hizalamayı bozmasın
    for d in rpage.get_drawings():
        r = d["rect"]
        if d.get("fill") == (1.0, 1.0, 1.0) and r.width * r.height > 1500 and r.width < 800:
            roi[int(r.y0 * SCALE):int(r.y1 * SCALE) + 1, int(r.x0 * SCALE):int(r.x1 * SCALE) + 1] = 0

    warp = np.eye(2, 3, dtype=np.float32)
    cc, warp = cv2.findTransformECC(landmask(ref) * roi, landmask(scn) * roi, warp, cv2.MOTION_AFFINE,
                                    (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 300, 1e-7), None, 5)
    print(f"Hizalama korelasyonu: {cc:.4f}\nAfin (referans px -> tarama px):\n{warp}", file=sys.stderr)
    if cc < 0.95:
        sys.exit("Hizalama başarısız görünüyor (korelasyon < 0.95). Haritalar aynı şablonda olmayabilir.")

    def to_scan(x, y):
        X, Y = x * SCALE, y * SCALE
        return ((warp[0, 0] * X + warp[0, 1] * Y + warp[0, 2]) / SCALE,
                (warp[1, 0] * X + warp[1, 1] * Y + warp[1, 2]) / SCALE)

    # Yeni sayfada köşe noktaları (MuPDF koordinatı, üst-sol orijin)
    sph = spage.rect.height
    new_corners = [to_scan(x, y) for x, y in corners]
    # Referansla aynı BBox; LPTS köşelerin bu BBox içindeki birim koordinatları
    new_lpts = []
    for x, y in new_corners:
        u = (x - bx0) / (bx1 - bx0)
        v = ((sph - y) - by0) / (by1 - by0)
        new_lpts += [u, v]

    out = pymupdf.open()
    out.insert_pdf(sdoc)
    page = out[0]
    # Lejant ve bilgi kutularını beyazla ört (sınıflandırmada maskelenir)
    for d in rpage.get_drawings():
        r = d["rect"]
        if d.get("fill") == (1.0, 1.0, 1.0) and r.width * r.height > 1500 and r.width < 800:
            p0 = to_scan(r.x0, r.y0); p1 = to_scan(r.x1, r.y1)
            page.draw_rect(pymupdf.Rect(p0, p1), color=None, fill=(1, 1, 1), overlay=True)

    gcs_wkt = None
    for x in range(1, rdoc.xref_length()):
        s = rdoc.xref_object(x)
        if "/Type /GEOGCS" in s:
            gcs_wkt = re.search(r"/WKT\s*\((.*)\)\s*>>", s, re.S).group(1)
    gcs = out.get_new_xref()
    out.update_object(gcs, f"<< /Type /GEOGCS /WKT ({gcs_wkt}) >>")
    meas = out.get_new_xref()
    fmt = lambda v: " ".join(f"{x:.8f}" for x in v)
    out.update_object(meas, f"<< /Type /Measure /Subtype /GEO /Bounds [ 0 1 0 0 1 0 1 1 ] "
                            f"/GPTS [ {fmt(gpts)} ] /LPTS [ {fmt(new_lpts)} ] /GCS {gcs} 0 R >>")
    out.xref_set_key(page.xref, "VP",
                     f"[ << /Type /Viewport /BBox [ {fmt(bbox)} ] /Measure {meas} 0 R >> ]")
    out.save(a.out, garbage=3, deflate=True)
    print(f"Kaydedildi: {a.out}", file=sys.stderr)

    if a.check:
        al = cv2.warpAffine(scn, warp, (w, h), flags=cv2.INTER_LINEAR + cv2.WARP_INVERSE_MAP)
        blend = (0.5 * ref + 0.5 * al).astype(np.uint8)
        cv2.imwrite(a.check, cv2.cvtColor(blend[y0:y1, x0:x1], cv2.COLOR_RGB2BGR)[::2, ::2])


if __name__ == "__main__":
    main()
