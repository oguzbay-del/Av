#!/usr/bin/env python3
"""Türkçe → İngilizce yerelleştirme kataloglarını üretir ve denetler.

Kaynak dil Türkçedir; anahtar metnin Türkçesidir. Anahtarlar üç yerden toplanır:
  1. Swift kodundaki L("…") çağrıları (yer tutucu: %@)
  2. SwiftUI'nin yerelleştirdiği sabit metinler: Text("…"), Button("…"), Toggle("…"), Section("…"),
     .navigationTitle("…") … (yalnızca araya değer eklenmemiş sabitler)
  3. Veri dosyalarındaki gösterilen metinler (MapData/*.json → LD(…))
Çeviriler `tools/l10n/en.json` içindedir ({"Türkçe": "English"}).

  python3 tools/l10n.py            # katalogları yaz (Localizable.xcstrings, InfoPlist.xcstrings)
  python3 tools/l10n.py --check    # eksik çeviri ya da yerelleştirilmemiş metin varsa hata ver
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOS = os.path.join(ROOT, "ios")
EN = os.path.join(ROOT, "tools", "l10n", "en.json")

SWIFTUI = r"(?:Text|Button|Toggle|Section|Label|LabeledContent|Picker|TextField|SecureField|Link|DatePicker|" \
          r"ContentUnavailableView|navigationTitle|accessibilityLabel|NavigationLink|Stepper)"
STR = r'"((?:[^"\\]|\\.)*)"'
L_CALL = re.compile(r'\bL\(\s*' + STR)
UI_CALL = re.compile(r'(?:\b|\.)' + SWIFTUI + r'\(\s*' + STR)
PROMPT = re.compile(r'prompt:\s*' + STR)
INFOPLIST_KEYS = ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
                  "NSMicrophoneUsageDescription", "NSLocalNetworkUsageDescription"]

# Veri dosyalarında gösterilen alanlar (kimlik, renk, tarih vb. hariç)
DATA_SKIP_KEYS = {"id", "key", "color", "file", "status", "level", "start", "end", "date", "fetched",
                  "validUntil", "name_of_file", "kind", "label"}


def unescape(s):
    return s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")


def swift_files(target):
    for d, _, fs in os.walk(os.path.join(IOS, target)):
        for f in fs:
            if f.endswith(".swift"):
                yield os.path.join(d, f)


def code_keys(targets):
    keys, problems = {}, []
    for t in targets:
        for path in swift_files(t):
            src = open(path, encoding="utf-8").read()
            # yorum satırlarını at
            src_nc = re.sub(r"(?m)^\s*//[^\n]*", "", src)  # yalnızca tam satır yorumlar (metin içindeki // bozulmasın)
            for rx in (L_CALL, UI_CALL, PROMPT):
                for m in rx.finditer(src_nc):
                    raw = m.group(1)
                    line = src_nc[:m.start()].count("\n") + 1
                    if "\\(" in raw:
                        if rx is not L_CALL:
                            problems.append(f"{os.path.relpath(path, ROOT)}:{line}: araya değer eklenmiş SwiftUI metni → L(\"… %@\", …) kullanın: {raw[:60]}")
                        else:
                            problems.append(f"{os.path.relpath(path, ROOT)}:{line}: L() anahtarında \\( var: {raw[:60]}")
                        continue
                    if not re.search(r"[A-Za-zÇĞİÖŞÜçğıöşü]", raw):
                        continue
                    keys.setdefault(unescape(raw), os.path.relpath(path, ROOT))
    return keys, problems


IGNORE_LINE = re.compile(r"systemImage:|forKey:|forResource|withExtension|identifier|id: \"|case \"|== \"|!= \"|"
                         r"\.key|kinds?:|rawValue|dateFormat|Europe/|https?://|UserDefaults|AppStorage|\.tag\(|"
                         r"setValue|fields\[|name: \"(?:latitude|longitude|hourly|wind|time|past|forecast)|"
                         r"resourceName|subdirectory|Bundle|appendingPathComponent|CLMonitor|static let identifier|"
                         r"ofType|contentType|httpMethod|\.json|\.bin|\.wav|\.png|font\(|withPurposeKey|"
                         r"UNNotificationRequest|\"%[.0-9]*[fd@]|format: \"|birdLabels|\"[a-z_]+\": \(")
ANY_STR = re.compile(STR)


def stray_literals(targets):
    """L()/LD()/SwiftUI dışında kalan, Türkçe görünen metinler (gözden geçirmek için)."""
    out = []
    for t in targets:
        for path in swift_files(t):
            for n, line in enumerate(open(path, encoding="utf-8"), 1):
                code = re.sub(r"//.*", "", line)
                if IGNORE_LINE.search(code):
                    continue
                for m in ANY_STR.finditer(code):
                    raw = m.group(1)
                    before = code[:m.start()]
                    if re.search(r"(?:\bL|\bLD|verbatim:|" + SWIFTUI + r")\(\s*$", before) or re.search(r"prompt:\s*$", before):
                        continue
                    if re.search(r"[çğıöşüÇĞİÖŞÜ]|\b(?:ve|ile|için|bir|yok|Açık|Kapat|Bitti)\b", raw):
                        out.append(f"{os.path.relpath(path, ROOT)}:{n}: {raw[:70]}")
    return out


def data_keys():
    keys = {}
    mapdata = os.path.join(IOS, "AvHaritasi", "MapData")

    def walk(o, k, f):
        if isinstance(o, dict):
            for kk, v in o.items():
                # huntableLatin/protectedLatin: anahtar Latince, değer Türkçe ad
                walk(v, kk, f)
        elif isinstance(o, list):
            for v in o:
                walk(v, k, f)
        elif isinstance(o, str) and k not in DATA_SKIP_KEYS and re.search(r"[A-Za-zçğıöşü]{2}", o) \
                and not re.fullmatch(r"[a-z0-9_]+", o):
            if o.endswith((".bin", ".json", ".tiles")) or o.startswith("http"):
                return
            keys.setdefault(o, f)

    for c in json.load(open(os.path.join(IOS, "AvHaritasi", "Sounds", "kus_sesleri_kunye.json"), encoding="utf-8")):
        for k in ("species", "use"):
            keys.setdefault(c[k], "kus_sesleri_kunye.json")
    for f in sorted(os.listdir(mapdata)):
        if f.endswith(".json") and not f.endswith(("features.json", "vectors.json")):
            walk(json.load(open(os.path.join(mapdata, f), encoding="utf-8")), "", f)
    return keys


def catalog(keys, en):
    strings = {}
    for k in sorted(keys):
        e = {"extractionState": "manual"}
        if k in en and en[k] is not None:
            e["localizations"] = {"en": {"stringUnit": {"state": "translated", "value": en[k]}}}
        strings[k] = e
    return {"sourceLanguage": "tr", "strings": strings, "version": "1.0"}


def write(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def main():
    check = "--check" in sys.argv
    en = json.load(open(EN, encoding="utf-8")) if os.path.exists(EN) else {}

    app, p1 = code_keys(["AvHaritasi", "Shared"])
    app.update({k: v for k, v in data_keys().items() if k not in app})
    widget, p2 = code_keys(["AvDurumWidget", "Shared"])
    problems = p1 + p2

    plist = {}
    import plistlib
    info = plistlib.load(open(os.path.join(IOS, "AvHaritasi-Info.plist"), "rb"))
    for k in INFOPLIST_KEYS:
        if k in info:
            plist[k] = info[k]
    tmp = info.get("NSLocationTemporaryUsageDescriptionDictionary", {})
    for k, v in tmp.items():
        plist[k] = v

    missing = sorted(k for k in list(app) + list(widget) + list(plist.values()) if not en.get(k))
    unused = sorted(k for k in en if k not in app and k not in widget and k not in plist.values())

    if not check:
        write(os.path.join(IOS, "AvHaritasi", "Localizable.xcstrings"), catalog(app, en))
        write(os.path.join(IOS, "AvDurumWidget", "Localizable.xcstrings"), catalog(widget, en))
        ip = catalog(plist.keys(), {k: en.get(v) for k, v in plist.items()})
        for k, v in plist.items():  # kaynak (tr) değeri de katalogda olsun
            ip["strings"][k].setdefault("localizations", {})["tr"] = {"stringUnit": {"state": "translated", "value": v}}
        write(os.path.join(IOS, "AvHaritasi", "InfoPlist.xcstrings"), ip)
        if missing:
            write(EN + ".todo", {k: "" for k in missing})
        elif os.path.exists(EN + ".todo"):
            os.remove(EN + ".todo")

    print(f"uygulama: {len(app)} anahtar, eklenti: {len(widget)}, Info.plist: {len(plist)}")
    print(f"eksik çeviri: {len(missing)}, kullanılmayan çeviri: {len(unused)}, sorun: {len(problems)}")
    for p in problems:
        print("  ✗", p)
    if "--stray" in sys.argv:
        for p in stray_literals(["AvHaritasi", "AvDurumWidget", "Shared"]):
            print("  ?", p)
    if check:
        for k in missing[:40]:
            print("  eksik:", k[:90])
        if missing or problems:
            sys.exit(1)


if __name__ == "__main__":
    main()
