#!/usr/bin/env python3
"""Destek ve gizlilik sayfalarının statik HTML sürümü (GitHub Pages: https://oguzbay-del.github.io/harita-veri/).

Tek kaynaklar: ios/AvHaritasi/Help/Kilavuz.json (kılavuz, tools/kilavuz.py üzerinden), docs/GIZLILIK.md ve
docs/PRIVACY.md. Çıktı docs/site/ altına yazılır; veri-deposu-esitle iş akışı bu klasörün içeriğini herkese açık
harita-veri deposunun köküne kopyalar (Pages: main dalı, kök klasör).

  docs/site/index.html             Türkçe destek + kılavuz
  docs/site/gizlilik/index.html    Türkçe gizlilik politikası (docs/GIZLILIK.md)
  docs/site/en/index.html          İngilizce destek + kılavuz
  docs/site/en/privacy/index.html  İngilizce gizlilik politikası (docs/PRIVACY.md)
  docs/site/icon.png               uygulama simgesi (AppIcon.png'den 192 px; Pillow varsa yeniden üretilir)
  docs/site/.nojekyll              Pages sayfaları olduğu gibi sunsun

Yalnızca Python standart kitaplığı kullanılır (simge küçültme hariç; --check simgenin yalnızca varlığına bakar).
Tasarım: satır içi CSS; harici yazı tipi, betik, çerez ya da izleyici yok. Bu modülü tools/kilavuz.py çağırır.
"""
import html
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "docs", "site")
ICON_SRC = os.path.join(ROOT, "ios", "AvHaritasi", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
ICON = os.path.join(SITE, "icon.png")
BASE = "https://oguzbay-del.github.io/harita-veri/"
# Yayımlanan adresler (uygulama, App Store metaverisi ve md kopyaları da bunları kullanır).
URL = {
    ("tr", "destek"): BASE,
    ("tr", "gizlilik"): BASE + "gizlilik/",
    ("en", "destek"): BASE + "en/",
    ("en", "gizlilik"): BASE + "en/privacy/",
}
# Sayfa → docs/site altındaki klasör.
DIR = {("tr", "destek"): "", ("tr", "gizlilik"): "gizlilik", ("en", "destek"): "en", ("en", "gizlilik"): "en/privacy"}

UI = {
    "tr": {
        "nav": ("Destek", "Gizlilik", "Kılavuz"), "other_lang": "EN", "other_label": "English",
        "s_title": "Destek", "privacy_title": "Gizlilik politikası",
        "skip": "İçeriğe geç", "footer": "Ücretsiz, çevrimdışı çalışan bir iPhone uygulaması. Reklam ve izleme yok.",
        "desc": "Av Haritası destek sayfası ve kullanım kılavuzu: İstanbul'da avcılar için çevrimdışı av haritası.",
        "pdesc": "Av Haritası gizlilik politikası.",
    },
    "en": {
        "nav": ("Support", "Privacy", "Guide"), "other_lang": "TR", "other_label": "Türkçe",
        "s_title": "Support", "privacy_title": "Privacy policy",
        "skip": "Skip to content", "footer": "A free iPhone app that works offline. No ads, no tracking.",
        "desc": "Av Haritası support page and user guide: an offline hunting map for Istanbul.",
        "pdesc": "Av Haritası privacy policy.",
    },
}

CSS = """
:root{--bg:#f5f4ee;--surface:#fffefa;--text:#1d2620;--muted:#4f5a4f;--accent:#2b5f39;--accent-soft:#e3ebdf;
--border:#d9d6c7;--link:#245e34;--note-bg:#f3eedd;--note-border:#b9a46e;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#111712;--surface:#18201a;--text:#e5e9e1;--muted:#a8b2a4;
--accent:#93c79f;--accent-soft:#223024;--border:#2f3b31;--link:#9fd2aa;--note-bg:#252418;--note-border:#8a7a4c;
color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",
Roboto,"Helvetica Neue",Arial,sans-serif;overflow-wrap:break-word}
.wrap{max-width:680px;margin:0 auto;padding:0 16px}
.skip{position:absolute;left:-999px;top:0}
.skip:focus{left:16px;top:8px;background:var(--surface);padding:8px 12px;border-radius:8px;z-index:9}
header{border-bottom:1px solid var(--border);background:var(--surface)}
.brand{display:flex;align-items:center;gap:12px;padding:16px 0 8px;color:var(--text);text-decoration:none}
.brand img{width:44px;height:44px;border-radius:10px;flex:none}
.brand span{font-size:1.25rem;font-weight:650;letter-spacing:-.01em}
nav ul{display:flex;flex-wrap:wrap;gap:4px;margin:0;padding:0 0 8px;list-style:none}
nav a{display:inline-flex;align-items:center;min-height:44px;padding:0 12px;border-radius:10px;
color:var(--link);text-decoration:none;font-weight:550}
nav a:hover,nav a:focus-visible{background:var(--accent-soft)}
nav a[aria-current=page]{background:var(--accent-soft);color:var(--text)}
nav li.lang{margin-left:auto}
main{padding:8px 0 32px}
h1{font-size:1.75rem;line-height:1.25;margin:24px 0 12px;letter-spacing:-.01em}
h2{font-size:1.3rem;line-height:1.3;margin:32px 0 8px}
h3{font-size:1.05rem;line-height:1.35;margin:20px 0 4px}
p,ul,ol{margin:0 0 14px}
ul,ol{padding-left:22px}
li{margin:0 0 8px}
a{color:var(--link);text-underline-offset:2px}
a:focus-visible,summary:focus-visible{outline:3px solid var(--accent);outline-offset:2px;border-radius:6px}
strong{font-weight:650}
code{font:.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--accent-soft);padding:1px 4px;
border-radius:4px}
hr{border:0;border-top:1px solid var(--border);margin:28px 0}
.muted{color:var(--muted)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:16px;margin:16px 0}
.card p:last-child{margin-bottom:0}
.note{background:var(--note-bg);border-left:4px solid var(--note-border);border-radius:10px;padding:12px 14px;
margin:16px 0}
.note p{margin:0}
details{background:var(--surface);border:1px solid var(--border);border-radius:14px;margin:10px 0}
summary{cursor:pointer;list-style:none;display:flex;align-items:center;justify-content:space-between;gap:12px;
min-height:52px;padding:10px 16px;font-weight:650;font-size:1.05rem}
summary::-webkit-details-marker{display:none}
summary::after{content:"";flex:none;width:9px;height:9px;border-right:2px solid var(--muted);
border-bottom:2px solid var(--muted);transform:rotate(45deg);margin-top:-4px;transition:transform .15s}
details[open] summary::after{transform:rotate(-135deg);margin-top:4px}
details[open] summary{border-bottom:1px solid var(--border)}
.topics{padding:0 16px 8px}
.topics h3:first-child{margin-top:14px}
.count{color:var(--muted);font-weight:400;font-size:.9rem;margin-left:auto}
table{width:100%;border-collapse:collapse;margin:0 0 16px;font-size:.95rem}
th,td{text-align:left;vertical-align:top;padding:10px;border-bottom:1px solid var(--border)}
th{background:var(--accent-soft)}
@media (max-width:620px){
 table,thead,tbody,tr,th,td{display:block}
 thead{position:absolute;left:-9999px}
 tr{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:6px 12px;margin:0 0 12px}
 td{border:0;padding:6px 0}
 td::before{content:attr(data-label);display:block;font-size:.8rem;font-weight:650;color:var(--muted);
 text-transform:uppercase;letter-spacing:.04em}
}
footer{border-top:1px solid var(--border);padding:20px 0 40px;color:var(--muted);font-size:.92rem}
footer p{margin:0 0 6px}
""".strip()

GENERATED = "<!-- Bu dosya tools/destek_site.py ile üretilir; elle düzenlemeyin. -->"


def esc(s):
    return html.escape(s, quote=True)


def slug(text):
    s = re.sub(r"[^\w\- ]", "", text.strip().lower(), flags=re.UNICODE)
    return re.sub(r"\s+", "-", s)


# --- Küçük Markdown dönüştürücü: başlık, paragraf, liste, tablo, kalın/italik, kod, bağlantı, ---, \* kaçışı ---

def inline(s):
    s = s.replace("\\*", "\x00")
    out, pos = [], 0
    for m in re.finditer(r"\[([^\]]+)\]\(([^)\s]+)\)", s):
        out.append(_fmt(s[pos:m.start()]))
        out.append(f'<a href="{esc(m.group(2))}">{_fmt(m.group(1))}</a>')
        pos = m.end()
    out.append(_fmt(s[pos:]))
    return "".join(out).replace("\x00", "*")


def _fmt(s):
    s = esc(s).replace("&#x27;", "'")
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<em>\1</em>", s)
    return s


def _cells(row):
    row = row.strip().strip("|")
    return [c.strip() for c in re.split(r"(?<!\\)\|", row)]


def markdown(md, skip_h1=False):
    """Belgede kullanılan Markdown alt kümesini HTML'e çevirir. (başlık, gövde) döner."""
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    lines = md.split("\n")
    out, title, i = [], None, 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = re.match(r"(#{1,6})\s+(.*)", line)
        if m:
            level, text = len(m.group(1)), m.group(2).strip()
            if level == 1 and title is None:
                title = text
                if skip_h1:
                    i += 1
                    continue
            out.append(f'<h{level} id="{esc(slug(text))}">{inline(text)}</h{level}>')
            i += 1
        elif re.match(r"^-{3,}\s*$", line):
            out.append("<hr>")
            i += 1
        elif line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}", lines[i + 1]):
            head = _cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(_cells(lines[i]))
                i += 1
            t = ["<table>", "<thead><tr>" + "".join(f"<th scope=\"col\">{inline(h)}</th>" for h in head)
                 + "</tr></thead>", "<tbody>"]
            for r in rows:
                t.append("<tr>" + "".join(
                    f'<td data-label="{esc(re.sub(r"[*_`]", "", head[j]) if j < len(head) else "")}">{inline(c)}</td>'
                    for j, c in enumerate(r)) + "</tr>")
            t += ["</tbody>", "</table>"]
            out.append("\n".join(t))
        elif re.match(r"^\s*[-*]\s+", line) or re.match(r"^\s*\d+\.\s+", line):
            ordered = bool(re.match(r"^\s*\d+\.\s+", line))
            items = []
            while i < len(lines) and lines[i].strip():
                cur = lines[i]
                mm = re.match(r"^\s*(?:[-*]|\d+\.)\s+(.*)", cur)
                if mm:
                    items.append(mm.group(1))
                elif items:  # devam satırı
                    items[-1] += " " + cur.strip()
                i += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>\n" + "\n".join(f"<li>{inline(it)}</li>" for it in items) + f"\n</{tag}>")
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"(#{1,6}\s|\s*[-*]\s|\s*\||-{3,}\s*$)",
                                                                         lines[i]):
                para.append(lines[i].strip())
                i += 1
            out.append(f"<p>{inline(' '.join(para))}</p>")
    return title, "\n".join(out)


# --- Sayfa iskeleti ---

def rel(frm, to):
    """docs/site içindeki iki sayfa klasörü arasında göreli bağlantı (sonu / ile)."""
    r = os.path.relpath(to or ".", frm or ".").replace(os.sep, "/")
    return "./" if r == "." else r + "/"


def page(lang, kind, title, desc, body):
    ui = UI[lang]
    here = DIR[(lang, kind)]
    other = "en" if lang == "tr" else "tr"
    root = rel(here, "")
    nav_items = [
        (rel(here, DIR[(lang, "destek")]), ui["nav"][0], kind == "destek", None),
        (rel(here, DIR[(lang, "gizlilik")]), ui["nav"][1], kind == "gizlilik", None),
        (rel(here, DIR[(lang, "destek")]) + "#kilavuz", ui["nav"][2], False, None),
        (rel(here, DIR[(other, kind)]), ui["other_lang"], False, other),
    ]
    nav = []
    for href, label, current, hl in nav_items:
        attrs = ' aria-current="page"' if current else ""
        if hl:
            attrs += f' hreflang="{hl}" lang="{hl}" title="{esc(UI[lang]["other_label"])}"'
        cls = ' class="lang"' if hl else ""
        nav.append(f'<li{cls}><a href="{esc(href)}"{attrs}>{esc(label)}</a></li>')
    alt = "".join(f'\n<link rel="alternate" hreflang="{lg}" href="{URL[(lg, kind)]}">' for lg in ("tr", "en"))
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · Av Haritası</title>
<meta name="description" content="{esc(desc)}">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f5f4ee" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#111712" media="(prefers-color-scheme: dark)">
<meta name="referrer" content="no-referrer">
<link rel="canonical" href="{URL[(lang, kind)]}">{alt}
<link rel="icon" type="image/png" href="{root}icon.png">
<link rel="apple-touch-icon" href="{root}icon.png">
<style>
{CSS}
</style>
</head>
<body>
{GENERATED}
<a class="skip" href="#icerik">{esc(ui["skip"])}</a>
<header><div class="wrap">
<a class="brand" href="{rel(here, DIR[(lang, "destek")])}"><img src="{root}icon.png" alt="" width="44" height="44"><span>Av Haritası</span></a>
<nav aria-label="{"Gezinme" if lang == "tr" else "Navigation"}"><ul>
{chr(10).join(nav)}
</ul></nav>
</div></header>
<main id="icerik" class="wrap">
{body}
</main>
<footer><div class="wrap">
<p>{esc(ui["footer"])}</p>
<p><a href="{rel(here, DIR[(lang, "gizlilik")])}">{esc(ui["privacy_title"])}</a> · <a href="{rel(here, DIR[(other, kind)])}" hreflang="{other}" lang="{other}">{esc(ui["other_label"])}</a></p>
</div></footer>
</body>
</html>
"""


def support_body(guide, lang, t, txt, contact):
    groups = [(b, [k for k in guide["konular"] if k["bolum"] == b["id"]]) for b in guide["bolumler"]]
    parts = [
        f"<h1>{esc(UI[lang]['s_title'])}</h1>",
        '<div class="card">',
        f"<p><strong>{esc(txt['s_contact'])}:</strong> {esc(contact)}</p>",
        f"<p>{esc(txt['s_help'])}</p>",
        "</div>",
        f'<div class="note" role="note"><p>{esc(txt["s_disclaimer"])}</p></div>',
        f'<h2 id="kilavuz">{esc(txt["s_guide"])}</h2>',
        f"<p>{esc(txt['intro'])}</p>",
    ]
    for b, ks in groups:
        bid = esc(slug(t(b["baslik"])))
        parts.append(f'<details id="{bid}">\n<summary><span>{esc(t(b["baslik"]))}</span>'
                     f'<span class="count">{len(ks)}</span></summary>\n<div class="topics">')
        for k in ks:
            parts.append(f'<h3 id="{esc(k["id"])}">{esc(t(k["baslik"]))}</h3>\n<p>{esc(t(k["metin"]))}</p>')
        parts.append("</div>\n</details>")
    return "\n".join(parts)


def render_all(guide, en, text, contact):
    """{docs/site'a göre yol: içerik} — HTML sayfaları ve .nojekyll."""
    files = {".nojekyll": ""}
    for lang in ("tr", "en"):
        def t(s, lang=lang):
            return s if lang == "tr" else (en.get(s) or s)
        txt = text[lang]
        body = support_body(guide, lang, t, txt, contact)
        files[os.path.join(DIR[(lang, "destek")], "index.html")] = page(
            lang, "destek", UI[lang]["s_title"], UI[lang]["desc"], body)
        src = os.path.join(ROOT, "docs", "GIZLILIK.md" if lang == "tr" else "PRIVACY.md")
        title, pbody = markdown(open(src, encoding="utf-8").read())
        files[os.path.join(DIR[(lang, "gizlilik")], "index.html")] = page(
            lang, "gizlilik", UI[lang]["privacy_title"], UI[lang]["pdesc"], pbody)
    return {k.replace(os.sep, "/"): v for k, v in files.items()}


def sync(guide, en, text, contact, check):
    """Siteyi yazar ya da (check) denetler; sorun listesi döner."""
    problems = []
    files = render_all(guide, en, text, contact)
    for relpath, content in files.items():
        path = os.path.join(SITE, relpath)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current == content:
            continue
        if check:
            problems.append(f"docs/site/{relpath} güncel değil → python3 tools/kilavuz.py çalıştırın")
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            print("yazıldı:", f"docs/site/{relpath}")
    # Fazla (artık üretilmeyen) sayfa kalmasın.
    if os.path.isdir(SITE):
        for d, _, fs in os.walk(SITE):
            for f in fs:
                relpath = os.path.relpath(os.path.join(d, f), SITE).replace(os.sep, "/")
                if relpath.endswith(".html") and relpath not in files:
                    problems.append(f"docs/site/{relpath} artık üretilmiyor → silin")
    if check:
        if not os.path.isfile(ICON):
            problems.append("docs/site/icon.png yok → python3 tools/kilavuz.py çalıştırın (Pillow gerekir)")
    else:
        try:
            from PIL import Image
            img = Image.open(ICON_SRC).convert("RGB").resize((192, 192), Image.LANCZOS)
            tmp = ICON + ".tmp"
            img.save(tmp, "PNG", optimize=True)
            if os.path.exists(ICON) and open(ICON, "rb").read() == open(tmp, "rb").read():
                os.remove(tmp)
            else:
                os.replace(tmp, ICON)
                print("yazıldı: docs/site/icon.png")
        except ImportError:
            if not os.path.isfile(ICON):
                problems.append("docs/site/icon.png üretilemedi: Pillow yok (pip install pillow)")
    return problems
