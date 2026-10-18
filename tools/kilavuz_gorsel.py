#!/usr/bin/env python3
"""Kılavuz ekran görüntülerini web sitesi için küçültür (yalnızca web; uygulama paketine girmez).

Girdi: screenshots/kilavuz/<tr|en>/<sahne>.png (KUME=kilavuz tools/appstore_screenshots.sh,
       iş akışı: .github/workflows/appstore-ekran.yml, kume=kilavuz)
Çıktı: docs/site/gorsel/<tr|en>/<sahne>.webp — en çok GENISLIK px genişlik, WebP kalite KALITE.
Kilavuz.json'da bir konunun `gorsel` alanı sahne adını verir; tools/kilavuz.py --check dosyanın varlığını denetler,
tools/destek_site.py görseli konunun altında gösterir.

  python3 tools/kilavuz_gorsel.py [girdi_klasörü]
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "screenshots", "kilavuz")
OUT = os.path.join(ROOT, "docs", "site", "gorsel")
GENISLIK = 600
KALITE = 72


def main():
    total, n = 0, 0
    for lang in ("tr", "en"):
        d = os.path.join(SRC, lang)
        if not os.path.isdir(d):
            continue
        os.makedirs(os.path.join(OUT, lang), exist_ok=True)
        for f in sorted(os.listdir(d)):
            if not f.endswith(".png"):
                continue
            im = Image.open(os.path.join(d, f)).convert("RGB")
            if im.width > GENISLIK:
                im = im.resize((GENISLIK, round(im.height * GENISLIK / im.width)), Image.LANCZOS)
            dst = os.path.join(OUT, lang, f[:-4] + ".webp")
            im.save(dst, "WEBP", quality=KALITE, method=6)
            size = os.path.getsize(dst)
            total += size
            n += 1
            print(f"{os.path.relpath(dst, ROOT)} {im.width}×{im.height} {size // 1024} KB")
    print(f"{n} görsel, toplam {total / 1048576:.2f} MB")
    if n == 0:
        sys.exit(f"görüntü bulunamadı: {SRC}")


if __name__ == "__main__":
    main()
