#!/usr/bin/env python3
"""
Taranmış (metin katmanı olmayan) MAK kararı PDF'ini Türkçe OCR ile metne çevirir.

  apt-get install tesseract-ocr tesseract-ocr-tur
  pip install pymupdf
  python3 tools/ocr_pdf.py maps/mak_2026_2027.pdf docs/mak_2026_2027_ocr.txt

Notlar:
  * Tesseract'ı tek iş parçacığıyla (OMP_THREAD_LIMIT=1) çalıştırıp sayfaları
    paralel işlemek çok daha hızlıdır; aksi halde iş parçacıkları çakışır ve
    sayfa başına dakikalar sürer.
  * Tablolar OCR'da bozulur; tablolu sayfalar (EK-1/2/3, EK Liste-1..7) görsel
    olarak okunmalıdır. Bkz. docs/MAK_2026_2027_okuma.md
"""
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor

import pymupdf


def ocr_page(args):
    src, i, tmp = args
    png = os.path.join(tmp, f"p{i + 1:03d}.png")
    out = os.path.join(tmp, f"p{i + 1:03d}")
    pymupdf.open(src)[i].get_pixmap(dpi=300, colorspace=pymupdf.csGRAY).save(png)
    subprocess.run(["tesseract", png, out, "-l", "tur", "--psm", "3"],
                   env={**os.environ, "OMP_THREAD_LIMIT": "1"}, capture_output=True, check=True)
    with open(out + ".txt", encoding="utf-8") as fh:
        return i, fh.read()


def main():
    src, dst = sys.argv[1], sys.argv[2]
    n = len(pymupdf.open(src))
    with tempfile.TemporaryDirectory() as tmp, ProcessPoolExecutor(os.cpu_count()) as ex:
        pages = dict(ex.map(ocr_page, [(src, i, tmp) for i in range(n)]))
    with open(dst, "w", encoding="utf-8") as fh:
        for i in range(n):
            fh.write(f"===== SAYFA {i + 1:03d} =====\n{pages[i]}")
    print(f"{n} sayfa -> {dst}")


if __name__ == "__main__":
    main()
