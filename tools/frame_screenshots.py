#!/usr/bin/env python3
"""App Store ekran görüntülerine başlık ve çerçeve ekler.

Girdi:  screenshots/appstore/<dil>/<n>_<ad>.png   (tools/appstore_screenshots.sh üretir)
Metin:  tools/appstore_copy.json                  ({"tr": {"1": {"headline", "subline", "note"?}}, ...})
Çıktı:  screenshots/appstore_framed/<dil>/<n>_<ad>.png  (aynı boyut, 1320×2868, alfa kanalsız)

Kullanım: python3 tools/frame_screenshots.py [--src DIR] [--dst DIR] [--copy JSON]
Gerekli: Pillow (python3 -m pip install --user pillow)
"""
import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
TOP = (0x2F, 0x68, 0x3E)      # uygulamanın orman yeşili
BOTTOM = (0x13, 0x36, 0x1F)
TEXT = (255, 255, 255)
SUBTEXT = (222, 236, 225)
NOTE = (186, 210, 192)
MARGIN = 96
SHOT_SCALE = 0.78             # ekran görüntüsü tuvalin genişliğine göre
CORNER = 170                  # tam boy ekran köşe yarıçapı (px, 1320 genişlikte)

FONT_CANDIDATES = {
    "bold": [
        ("/System/Library/Fonts/SFNS.ttf", "Bold"),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", None),
        ("/Library/Fonts/Arial Bold.ttf", None),
        ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", None),
    ],
    "regular": [
        ("/System/Library/Fonts/SFNS.ttf", "Regular"),
        ("/System/Library/Fonts/Supplemental/Arial.ttf", None),
        ("/Library/Fonts/Arial.ttf", None),
        ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", None),
    ],
}


def font(kind: str, size: int) -> ImageFont.FreeTypeFont:
    for path, variation in FONT_CANDIDATES[kind]:
        if not Path(path).exists():
            continue
        try:
            f = ImageFont.truetype(path, size)
            if variation:
                try:
                    f.set_variation_by_name(variation)
                except Exception:
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default(size)


def wrap(draw: ImageDraw.ImageDraw, text: str, fnt, width: int) -> list[str]:
    lines, cur = [], ""
    for word in text.split():
        trial = f"{cur} {word}".strip()
        if draw.textlength(trial, font=fnt) <= width or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def fit_lines(draw, text, kind, size, min_size, width, max_lines):
    """Metni en fazla max_lines satıra sığacak en büyük punto ile böler."""
    while True:
        fnt = font(kind, size)
        lines = wrap(draw, text, fnt, width)
        if len(lines) <= max_lines or size <= min_size:
            return fnt, lines
        size -= 4


def gradient() -> Image.Image:
    col = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        col.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return col.resize((W, H))


def rounded_mask(size, radius) -> Image.Image:
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return m


def frame(src: Path, caption: dict, dst: Path) -> None:
    shot = Image.open(src).convert("RGB")
    canvas = gradient()
    draw = ImageDraw.Draw(canvas)
    text_w = W - 2 * MARGIN

    # Başlık bloğu
    y = 150
    hf, hlines = fit_lines(draw, caption["headline"], "bold", 100, 72, text_w, 2)
    for line in hlines:
        lw = draw.textlength(line, font=hf)
        draw.text(((W - lw) / 2, y), line, font=hf, fill=TEXT)
        y += round(hf.size * 1.18)
    y += 22
    sub = caption.get("subline", "")
    if sub:
        sf, slines = fit_lines(draw, sub, "regular", 52, 40, text_w, 2)
        for line in slines:
            lw = draw.textlength(line, font=sf)
            draw.text(((W - lw) / 2, y), line, font=sf, fill=SUBTEXT)
            y += round(sf.size * 1.3)
    note = caption.get("note", "")
    if note:
        nf = font("regular", 34)
        y += 8
        lw = draw.textlength(note, font=nf)
        draw.text(((W - lw) / 2, y), note, font=nf, fill=NOTE)
        y += round(nf.size * 1.3)

    # Ekran görüntüsü: başlığın altına, alt kenarda pay kalacak biçimde
    top = max(y + 70, 600)
    avail_h = H - top - 110
    scale = min(SHOT_SCALE, avail_h / shot.height)
    sw, sh = round(shot.width * scale), round(shot.height * scale)
    small = shot.resize((sw, sh), Image.LANCZOS)
    radius = round(CORNER * scale)
    x = (W - sw) // 2

    # Yumuşak gölge
    pad = 80
    shadow = Image.new("L", (sw + 2 * pad, sh + 2 * pad), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad, pad + sw, pad + sh), radius=radius, fill=120)
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    black = Image.new("RGB", shadow.size, (0, 0, 0))
    canvas.paste(black, (x - pad, top - pad + 24), shadow)

    # İnce açık kenar (cihaz çerçevesi hissi)
    border = 6
    edge = Image.new("RGB", (sw + 2 * border, sh + 2 * border), (20, 28, 22))
    canvas.paste(edge, (x - border, top - border), rounded_mask(edge.size, radius + border))
    canvas.paste(small, (x, top), rounded_mask((sw, sh), radius))

    dst.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dst, "PNG", optimize=True)
    assert canvas.size == (W, H) and canvas.mode == "RGB"
    print(f"  {dst}")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=root / "screenshots/appstore")
    ap.add_argument("--dst", type=Path, default=root / "screenshots/appstore_framed")
    ap.add_argument("--copy", type=Path, default=root / "tools/appstore_copy.json")
    args = ap.parse_args()

    copy = json.loads(args.copy.read_text(encoding="utf-8"))
    count = 0
    for lang, captions in copy.items():
        files = sorted((args.src / lang).glob("*.png"))
        if not files:
            print(f"Uyarı: {args.src / lang} içinde görüntü yok", file=sys.stderr)
        for f in files:
            key = f.stem.split("_", 1)[0]
            if key not in captions:
                print(f"Uyarı: {lang}/{f.name} için metin yok, atlandı", file=sys.stderr)
                continue
            frame(f, captions[key], args.dst / lang / f.name)
            count += 1
    if count == 0:
        print("Hiç görüntü çerçevelenmedi", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
