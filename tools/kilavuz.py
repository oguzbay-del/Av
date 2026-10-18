#!/usr/bin/env python3
"""Kullanım kılavuzunu tek kaynaktan (ios/AvHaritasi/Help/Kilavuz.json) üretir ve eşitliğini denetler.

Kilavuz.json uygulamaya gömülüdür: Ayarlar › Yardım ekranı (KilavuzView) ve ilk açılış tanıtımı (TanitimView,
`tanitim: true` konular) doğrudan onu okur. Bu araç aynı dosyadan web kopyalarını yazar:
  docs/KILAVUZ.md     (Türkçe)
  docs/USER_GUIDE.md  (İngilizce; çeviriler tools/l10n/en.json'dan, uygulamadaki LD() ile aynı anahtarlar)
  docs/DESTEK.md, docs/SUPPORT.md  (App Store "Destek URL'si" sayfası: kısa başlık, iletişim, gizlilik bağlantısı
                      ve kılavuzun tamamı; veri-deposu-esitle iş akışı bunları herkese açık harita-veri deposuna kopyalar)
  docs/site/          aynı destek sayfası ve gizlilik politikası, statik HTML olarak (tools/destek_site.py;
                      GitHub Pages: https://oguzbay-del.github.io/harita-veri/)

  python3 tools/kilavuz.py           # docs altındaki dört dosyayı ve docs/site'ı yaz
  python3 tools/kilavuz.py --check   # denetle (CI: .github/workflows/lint.yml), sorun varsa çıkış kodu 1

Denetimler:
  1. Şema: kimlikler benzersiz, her konunun bölümü tanımlı, başlık/metin/kaynak dolu, 1–5 tanıtım konusu.
  2. Her `kaynak` yolu depoda var (dosya taşındı ya da silindiyse kılavuz da güncellenmeli).
  3. docs/KILAVUZ.md, docs/USER_GUIDE.md, docs/DESTEK.md ve docs/SUPPORT.md ile docs/site/ güncel (Kilavuz.json, gizlilik metni ya da çeviri değişip araç çalıştırılmadıysa hata).
  4. İngilizce çevirisi eksik başlık/metin yok.
  5. Ekran kuralı: ios/AvHaritasi altında bir "ekran dosyası" hiçbir konunun `kaynak`ında ve `haric` listesinde
     yoksa hata. Ekran dosyası = adı *View.swift / *Views.swift olan ya da Views/, Presentation/, Help/
     klasörlerinde duran ve en az bir private olmayan, üst düzey `struct …: View` (ya da
     UIViewRepresentable / UIViewControllerRepresentable) tanımlayan Swift dosyası. Yani kullanıcıya görünen
     yeni bir ekran eklendiğinde ya kılavuza bir konu yazılır ya da (yardımcı görünümse) gerekçesiyle `haric`e
     eklenir.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import destek_site  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "ios", "AvHaritasi", "Help", "Kilavuz.json")
EN = os.path.join(ROOT, "tools", "l10n", "en.json")
APP = os.path.join(ROOT, "ios", "AvHaritasi")
# (dil, tür) → çıktı. "kilavuz": depodaki kılavuz; "destek": harita-veri'de yayımlanan destek sayfası.
OUT = {
    ("tr", "kilavuz"): os.path.join(ROOT, "docs", "KILAVUZ.md"),
    ("en", "kilavuz"): os.path.join(ROOT, "docs", "USER_GUIDE.md"),
    ("tr", "destek"): os.path.join(ROOT, "docs", "DESTEK.md"),
    ("en", "destek"): os.path.join(ROOT, "docs", "SUPPORT.md"),
}
# İletişim, gizlilik metnindeki yer tutucuyla aynı; yayından önce ikisi birlikte doldurulur (docs/YAYIN.md).
CONTACT = "[Geliştirici adı / e-posta]"

SCREEN_DIRS = {"Views", "Presentation", "Help"}
SCREEN_STRUCT = re.compile(r"^(?:public\s+|internal\s+)?struct\s+\w+(?:<[^>{]*>)?\s*:[^{]*"
                           r"\b(?:View|UIViewRepresentable|UIViewControllerRepresentable)\b", re.M)

TEXT = {
    "tr": {
        "title": "Av Haritası — Kullanım kılavuzu",
        "intro": "Av Haritası, İstanbul'da avcılar için ava yasak ve avlanabilir alanları, MAK 2026-27 kurallarını, "
                 "av gününü ve saatini gösteren, kuşu sesinden, fotoğrafından ve videosundan tanımaya yardım eden ücretsiz "
                 "bir iPhone uygulamasıdır. Uygulama internetsiz çalışır. Bu kılavuz uygulamanın içinde de vardır "
                 "(Ayarlar › Yardım).",
        "contents": "İçindekiler",
        "privacy": "Gizlilik politikası",
        "privacy_url": destek_site.URL[("tr", "gizlilik")],
        "other": "English version: [USER_GUIDE.md](USER_GUIDE.md)",
        "s_title": "Av Haritası — Destek",
        "s_other": "English: [Support](SUPPORT.md)",
        "s_contact": "İletişim",
        "s_help": "Soru, hata bildirimi ve önerileriniz için yukarıdaki adrese yazın. Uygulamanın kullanımı "
                  "aşağıdaki kılavuzda anlatılır; aynı kılavuz uygulamada da vardır (Ayarlar › Yardım).",
        "s_disclaimer": "Uygulama resmi değildir; avlanma kurallarına uymak ve yasal sorumluluk avcıya aittir.",
        "s_guide": "Kullanım kılavuzu",
    },
    "en": {
        "title": "Av Haritası — User guide",
        "intro": "Av Haritası is a free iPhone app for hunters in Istanbul. It shows no-hunting and huntable areas, "
                 "the MAK 2026-27 rules and hunting days and hours, and helps identify birds by sound, photo and video. "
                 "The app works without internet. This guide is also built into the app (Settings › Help).",
        "contents": "Contents",
        "privacy": "Privacy policy",
        "privacy_url": destek_site.URL[("en", "gizlilik")],
        "other": "Türkçe sürüm: [KILAVUZ.md](KILAVUZ.md)",
        "s_title": "Av Haritası — Support",
        "s_other": "Türkçe: [Destek](DESTEK.md)",
        "s_contact": "Contact",
        "s_help": "For questions, bug reports and suggestions, write to the address above. How to use the app is "
                  "explained in the guide below; the same guide is built into the app (Settings › Help).",
        "s_disclaimer": "The app is not official; following the hunting rules and legal responsibility rest "
                        "with the hunter.",
        "s_guide": "User guide",
    },
}
NOTE = "<!-- Bu dosya tools/kilavuz.py ile ios/AvHaritasi/Help/Kilavuz.json'dan üretilir; elle düzenlemeyin. -->"


def load():
    with open(SRC, encoding="utf-8") as f:
        guide = json.load(f)
    en = json.load(open(EN, encoding="utf-8")) if os.path.exists(EN) else {}
    return guide, en


def validate(guide):
    problems = []
    bolumler = guide.get("bolumler", [])
    konular = guide.get("konular", [])
    bolum_ids = [b.get("id") for b in bolumler]
    for name, ids in (("bölüm", bolum_ids), ("konu", [k.get("id") for k in konular])):
        seen = set()
        for i in ids:
            if not i:
                problems.append(f"kimliği olmayan {name}")
            elif i in seen:
                problems.append(f"yinelenen {name} kimliği: {i}")
            seen.add(i)
    for b in bolumler:
        if not b.get("baslik"):
            problems.append(f"bölüm {b.get('id')}: başlık yok")
        if not any(k.get("bolum") == b.get("id") for k in konular):
            problems.append(f"bölüm {b.get('id')}: hiç konusu yok")
    for k in konular:
        kid = k.get("id")
        if k.get("bolum") not in bolum_ids:
            problems.append(f"konu {kid}: tanımsız bölüm {k.get('bolum')!r}")
        for field in ("baslik", "metin"):
            if not (k.get(field) or "").strip():
                problems.append(f"konu {kid}: {field} boş")
        if not k.get("kaynak"):
            problems.append(f"konu {kid}: kaynak listesi boş")
        for p in k.get("kaynak", []):
            if not os.path.isfile(os.path.join(ROOT, p)):
                problems.append(f"konu {kid}: kaynak dosya yok: {p}")
    for h in guide.get("haric", []):
        if not os.path.isfile(os.path.join(ROOT, h.get("yol", ""))):
            problems.append(f"haric: dosya yok: {h.get('yol')}")
        if not h.get("neden"):
            problems.append(f"haric: gerekçe yok: {h.get('yol')}")
    n = sum(1 for k in konular if k.get("tanitim"))
    if not 1 <= n <= 5:
        problems.append(f"tanıtım konusu sayısı {n} (1–5 olmalı)")
    return problems


def screen_files():
    """Kurala göre kılavuzda yer alması gereken ekran dosyaları (depo köküne göre yollar)."""
    out = []
    for d, _, fs in os.walk(APP):
        for f in fs:
            if not f.endswith(".swift"):
                continue
            path = os.path.join(d, f)
            in_dir = os.path.basename(d) in SCREEN_DIRS
            named = f.endswith(("View.swift", "Views.swift"))
            if not (in_dir or named):
                continue
            src = open(path, encoding="utf-8").read()
            if SCREEN_STRUCT.search(src):
                out.append(os.path.relpath(path, ROOT).replace(os.sep, "/"))
    return sorted(out)


def unreferenced_screens(guide):
    referenced = {p for k in guide.get("konular", []) for p in k.get("kaynak", [])}
    excluded = {h.get("yol") for h in guide.get("haric", [])}
    return [p for p in screen_files() if p not in referenced and p not in excluded]


def anchor(text):
    """GitHub başlık bağlantısı: küçük harf, harf/rakam/boşluk/tire kalır, boşluk → tire."""
    s = text.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s, flags=re.UNICODE)
    return s.replace(" ", "-")


def render(guide, lang, en, kind="kilavuz"):
    def t(s):
        return s if lang == "tr" else (en.get(s) or s)

    txt = TEXT[lang]
    if kind == "destek":
        lines = [NOTE, "", f"# {txt['s_title']}", "", txt["s_other"], "",
                 f"**{txt['s_contact']}:** {CONTACT}", "", txt["s_help"], "",
                 f"[{txt['privacy']}]({txt['privacy_url']})", "", f"_{txt['s_disclaimer']}_", "",
                 f"# {txt['s_guide']}", "", txt["intro"], "", f"## {txt['contents']}", ""]
    else:
        lines = [NOTE, "", f"# {txt['title']}", "", txt["intro"], "", txt["other"], "", f"## {txt['contents']}", ""]
    groups = [(b, [k for k in guide["konular"] if k["bolum"] == b["id"]]) for b in guide["bolumler"]]
    for b, ks in groups:
        lines.append(f"- [{t(b['baslik'])}](#{anchor(t(b['baslik']))})")
    lines.append("")
    for b, ks in groups:
        lines += [f"## {t(b['baslik'])}", ""]
        for k in ks:
            lines += [f"### {t(k['baslik'])}", "", t(k["metin"]), ""]
    lines += ["---", "", f"[{txt['privacy']}]({txt['privacy_url']})", ""]
    return "\n".join(lines)


def missing_translations(guide, en):
    keys = [b["baslik"] for b in guide["bolumler"]]
    keys += [s for k in guide["konular"] for s in (k["baslik"], k["metin"])]
    return [k for k in keys if not en.get(k)]


def main():
    check = "--check" in sys.argv
    guide, en = load()
    problems = validate(guide)
    if problems:  # şema bozuksa üretme
        for p in problems:
            print("  ✗", p)
        sys.exit(1)

    problems += [f"İngilizce çeviri yok (tools/l10n/en.json, sonra python3 tools/l10n.py): {k[:70]}"
                 for k in missing_translations(guide, en)]
    problems += [f"ekran dosyası kılavuzda yok: {p} → Kilavuz.json'da bir konunun kaynak'ına ya da "
                 f"gerekçesiyle haric'e ekleyin" for p in unreferenced_screens(guide)]

    for (lang, kind), path in OUT.items():
        text = render(guide, lang, en, kind)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if check:
            if current != text:
                problems.append(f"{os.path.relpath(path, ROOT)} güncel değil → python3 tools/kilavuz.py çalıştırın")
        elif current != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            print("yazıldı:", os.path.relpath(path, ROOT))

    problems += destek_site.sync(guide, en, TEXT, CONTACT, check)

    print(f"kılavuz: {len(guide['bolumler'])} bölüm, {len(guide['konular'])} konu, "
          f"{sum(1 for k in guide['konular'] if k.get('tanitim'))} tanıtım sayfası, "
          f"{len(screen_files())} ekran dosyası denetlendi; sorun: {len(problems)}")
    for p in problems:
        print("  ✗", p)
    if problems and check:
        sys.exit(1)


if __name__ == "__main__":
    main()
