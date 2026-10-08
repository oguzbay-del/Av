#!/usr/bin/env python3
"""Avcılığa özgü özel SF Symbols (ördek, bıldırcın, yaban domuzu) üretir.

Şekiller basit geometrik parçalardan (elips, çokgen) birleştirilir (shapely), SF Symbols
şablonuna (Regular-M) yerleştirilir ve Assets.xcassets/<ad>.symbolset olarak yazılır.
SwiftUI'de: Image("av.ordek") — sistem simgeleri gibi yazı boyutu ve renkle ölçeklenir.

  python3 tools/make_symbols.py ios/AvHaritasi/Assets.xcassets [--preview önizleme.png]
Gerekli: shapely (pip install shapely); önizleme için cairosvg.
"""
import json
import math
import os
import sys

from shapely import affinity
from shapely.geometry import Point, Polygon
from shapely.ops import unary_union

CAP = 70.459  # SF Symbols şablonunda Regular-M büyük harf yüksekliği (birim)


def ellipse(cx, cy, rx, ry, rot=0):
    e = affinity.scale(Point(0, 0).buffer(1, 64), rx, ry)
    return affinity.translate(affinity.rotate(e, rot), cx, cy)


def poly(*pts):
    return Polygon(pts)


# Koordinatlar: x sağa, y YUKARI; taban çizgisi y=0, yükseklik ~ CAP
def duck():
    body = ellipse(44, 22, 32, 16, -4)
    tail = poly((14, 28), (6, 40), (24, 30))
    head = ellipse(72, 49, 12, 11)
    neck = poly((62, 30), (77, 33), (80, 45), (64, 44))
    bill = poly((81, 51), (95, 46), (95, 43), (81, 43))
    # Kanat: elipsin yalnızca üst yayı (ince çizgi boşluk)
    wing = ellipse(42, 24, 19, 8, -6).exterior.buffer(2.0)
    wing = wing.intersection(poly((18, 25), (66, 25), (66, 40), (18, 40)))
    shape = unary_union([body, tail, head, neck, bill]).difference(wing)
    eye = Point(75, 52).buffer(2.6, 24)
    return shape.difference(eye)


def quail():
    body = ellipse(46, 30, 34, 26)
    head = ellipse(76, 54, 13, 12)
    bill = poly((87, 56), (96, 52), (87, 50))
    plume = unary_union([ellipse(74, 70, 3.2, 7, -25), Point(77, 75).buffer(4.2, 24)])
    tail = poly((14, 34), (4, 30), (14, 22))
    leg1 = poly((40, 6), (44, 6), (42, -6), (38, -6))
    leg2 = poly((54, 6), (58, 6), (58, -6), (54, -6))
    shape = unary_union([body, head, bill, plume, tail, leg1, leg2])
    eye = Point(79, 56).buffer(2.4, 24)
    spots = [Point(x, y).buffer(2.2, 16) for x, y in [(34, 34), (44, 24), (52, 36), (30, 22)]]
    return shape.difference(unary_union([eye] + spots))


def boar():
    body = ellipse(44, 30, 34, 19)
    head = poly((66, 44), (88, 34), (100, 22), (100, 14), (74, 12), (62, 22))
    snout = ellipse(100, 18, 4.5, 6)
    ear = poly((70, 43), (74, 54), (79, 42))
    mane = poly((20, 42), (26, 50), (36, 48), (46, 52), (56, 48), (64, 50), (68, 40), (22, 38))
    tail = poly((11, 36), (3, 41), (4, 35), (12, 31))
    legs = [poly((x, 16), (x + 8, 16), (x + 7, -6), (x + 1, -6)) for x in (18, 31, 56, 67)]
    shape = unary_union([body, head, snout, ear, mane, tail] + legs)
    tusk = poly((88, 13), (95, 5), (91, 14)).buffer(0.8)
    eye = Point(82, 28).buffer(2.4, 24)
    return unary_union([shape, tusk]).difference(eye)


SYMBOLS = {"av.ordek": duck, "av.bildircin": quail, "av.domuz": boar}


def to_path(geom, scale, dx):
    """Shapely geometrisi → SVG yolu (şablon koordinatı: y aşağı, taban çizgisinden yukarısı negatif)."""
    geoms = getattr(geom, "geoms", [geom])
    parts = []
    for g in geoms:
        for ring in [g.exterior] + list(g.interiors):
            pts = list(ring.coords)
            d = "M" + " L".join(f"{(x * scale + dx):.2f} {(-y * scale):.2f}" for x, y in pts) + " Z"
            parts.append(d)
    return " ".join(parts)


TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--glyph: "{name}", point size: 100.0, template writer version: "138.0.0"-->
 <g id="Notes">
  <text style="font-family:'SFProText-Regular';font-size:13" x="18" y="1863" id="template-version">Template v.3.0</text>
  <text style="font-family:'SFProText-Regular';font-size:13" x="18" y="1880">Requires Xcode 13 or greater</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="Capline-S" x1="263" x2="3036" y1="625.541" y2="625.541" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="Baseline-M" x1="263" x2="3036" y1="1126" y2="1126" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="Capline-M" x1="263" x2="3036" y1="1055.54" y2="1055.54" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="Capline-L" x1="263" x2="3036" y1="1485.54" y2="1485.54" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
  <line id="left-margin-Regular-M" x1="{left:.2f}" x2="{left:.2f}" y1="1030.79" y2="1150.12" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"/>
  <line id="right-margin-Regular-M" x1="{right:.2f}" x2="{right:.2f}" y1="1030.79" y2="1150.12" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {left:.2f} 1126)">
   <path d="{path}"/>
  </g>
 </g>
</svg>
"""


def build(name, fn):
    g = fn()
    minx, miny, maxx, maxy = g.bounds
    scale = (CAP * 1.08) / (maxy - miny)          # tam yükseklik ~ büyük harf yüksekliğinin biraz üstü
    g = affinity.translate(g, -minx, -miny - (maxy - miny) * 0.06)  # tabanın biraz altına sarksın (ayaklar)
    width = (maxx - minx) * scale
    left = 1391.0
    path = to_path(g, scale, 0)
    return TEMPLATE.format(name=name, left=left, right=left + width, path=path), path, width


def main():
    dst = sys.argv[1]
    preview = sys.argv[sys.argv.index("--preview") + 1] if "--preview" in sys.argv else None
    rendered = []
    for name, fn in SYMBOLS.items():
        svg, path, width = build(name, fn)
        d = os.path.join(dst, name + ".symbolset")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, name + ".svg"), "w").write(svg)
        json.dump({"info": {"author": "xcode", "version": 1},
                   "symbols": [{"filename": name + ".svg", "idiom": "universal"}]},
                  open(os.path.join(d, "Contents.json"), "w"), indent=2)
        rendered.append((path, width))
        print(name, f"genişlik {width:.1f}")
    if preview:
        import cairosvg
        cells = "".join(
            f'<g transform="translate({20 + i * 170} 130) scale(1.5)"><path d="{p}" fill="#1f4d2b"/></g>'
            for i, (p, w) in enumerate(rendered))
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{40 + 170 * len(rendered)}" height="170">' \
              f'<rect width="100%" height="100%" fill="#f4f4f0"/>{cells}</svg>'
        cairosvg.svg2png(bytestring=svg.encode(), write_to=preview)


if __name__ == "__main__":
    main()
