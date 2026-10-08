#!/usr/bin/env python3
"""Uygulama ikonunu üretir (1024×1024; aydınlık, koyu ve renklendirilmiş sürümler).

Tasarım: orman yeşili zemin üzerinde ince eş yükselti çizgileri (harita), beyaz konum iğnesi,
iğnenin içinde avcı turuncusu halka ve uçan kuş silüeti.

  python3 tools/make_app_icon.py ios/AvHaritasi/Assets.xcassets/AppIcon.appiconset
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4096            # 4× örnekleme, sonra 1024'e küçültülür
C = S / 2


def bezier(p0, p1, p2, p3, n=60):
    t = np.linspace(0, 1, n)[:, None]
    return ((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3).tolist()


def bird(cx, cy, scale):
    """Süzülen kuş: iki kanat (kübik Bezier) + gövde."""
    P = lambda x, y: np.array([x, y], float)
    left = (bezier(P(0, 0.04), P(-0.22, -0.38), P(-0.62, -0.42), P(-1.0, -0.16))
            + bezier(P(-1.0, -0.16), P(-0.66, -0.16), P(-0.34, -0.06), P(-0.04, 0.2)))
    right = [(-x, y) for x, y in left][::-1]
    pts = left + right
    return [(cx + x * scale, cy + y * scale) for x, y in pts]


def contours(draw, color, width):
    """Rastgele görünen ama sabit eş yükselti çizgileri (iki tepe)."""
    for (hx, hy, base) in [(0.28, 0.30, 0.10), (0.78, 0.80, 0.08)]:
        for k in range(1, 9):
            r = base + k * 0.055
            pts = []
            for a in np.linspace(0, 2 * math.pi, 240):
                wob = 1 + 0.07 * math.sin(3 * a + k) + 0.04 * math.sin(5 * a - k * 0.7)
                pts.append((S * (hx + r * wob * math.cos(a)), S * (hy + 0.8 * r * wob * math.sin(a))))
            draw.line(pts + [pts[0]], fill=color, width=width, joint="curve")


def pin_shape(draw, cx, top, w, fill):
    """Damla biçimli konum iğnesi: üstte daire, altta sivri uç."""
    r = w / 2
    cy = top + r
    tip = (cx, top + w * 1.42)
    # Teğet noktaları: uçtan daireye
    d = tip[1] - cy
    ang = math.asin(r / d)
    tx = r * math.cos(ang)
    ty = cy + r * math.sin(ang)
    draw.ellipse([cx - r, top, cx + r, top + w], fill=fill)
    draw.polygon([(cx - tx, ty), (cx + tx, ty), tip], fill=fill)
    return cy, r


def render(variant):
    if variant == "tinted":
        bg_top, bg_bot = (0, 0, 0), (0, 0, 0)
    elif variant == "dark":
        bg_top, bg_bot = (18, 38, 24), (6, 16, 10)
    else:
        bg_top, bg_bot = (47, 104, 62), (19, 54, 31)
    grad = np.linspace(0, 1, S)[:, None, None]
    bg = (np.array(bg_top) * (1 - grad) + np.array(bg_bot) * grad).astype(np.uint8)
    img = Image.fromarray(np.repeat(bg, S, axis=1), "RGB").convert("RGBA")

    lines = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    contours(ImageDraw.Draw(lines), (255, 255, 255, 30 if variant != "tinted" else 45), 10)
    img.alpha_composite(lines)

    # Gölge
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pin_shape(ImageDraw.Draw(shadow), C, S * 0.20 + 40, S * 0.46, (0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(60)))

    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    pin_color = {"light": (250, 248, 240), "dark": (226, 238, 228), "tinted": (235, 235, 235)}[variant]
    cy, r = pin_shape(d, C, S * 0.20, S * 0.46, pin_color + (255,))
    ring = {"light": (233, 118, 43), "dark": (240, 135, 60), "tinted": (150, 150, 150)}[variant]
    ri = r * 0.80
    d.ellipse([C - ri, cy - ri, C + ri, cy + ri], fill=ring + (255,))
    inner = {"light": (31, 77, 43), "dark": (24, 52, 32), "tinted": (40, 40, 40)}[variant]
    rj = r * 0.64
    d.ellipse([C - rj, cy - rj, C + rj, cy + rj], fill=inner + (255,))
    d.polygon(bird(C, cy + r * 0.10, r * 0.62), fill=pin_color + (255,))
    img.alpha_composite(fg)

    out = img.resize((1024, 1024), Image.LANCZOS)
    if variant == "tinted":
        out = out.convert("L").convert("RGBA")
    return out.convert("RGB")


def main(dst):
    os.makedirs(dst, exist_ok=True)
    files = {"light": "AppIcon.png", "dark": "AppIcon-Dark.png", "tinted": "AppIcon-Tinted.png"}
    for v, f in files.items():
        render(v).save(os.path.join(dst, f), optimize=True)
    contents = {
        "images": [
            {"filename": files["light"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": files["dark"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": files["tinted"], "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    json.dump(contents, open(os.path.join(dst, "Contents.json"), "w"), indent=2)
    root = os.path.dirname(dst.rstrip("/"))
    if not os.path.exists(os.path.join(root, "Contents.json")):
        json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(root, "Contents.json"), "w"), indent=2)
    print("Tamam:", dst)


if __name__ == "__main__":
    main(sys.argv[1])
