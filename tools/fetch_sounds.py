#!/usr/bin/env python3
"""Uygulama seslerini Xeno-canto'daki gerçek kuş kayıtlarından üretir.

Her kayıt için: indir → lisansı denetle (ND yasak; kırpma bir "değişiklik"tir) →
en yüksek enerjili pencereyi bul → kırp, yumuşak giriş/çıkış, ses düzeyi normalleştir →
44.1 kHz mono 16-bit WAV (iOS bildirim sesi biçimi, < 30 sn) → künye (credits) JSON.

Kullanım:
  python3 tools/fetch_sounds.py ios/AvHaritasi/Sounds
İsteğe bağlı doğrulama (BirdNET kuruluysa): --verify
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

import numpy as np

# (dosya adı, XC no, süre sn, Türkçe ad, bilimsel ad, kullanım)
SOUNDS = [
    ("kus_acilis", 1048930, 2.6, "Kınalı keklik", "Alectoris chukar", "Uygulama açılışı"),
    ("kus_kapanis", 1080723, 1.6, "Kızılgerdan", "Erithacus rubecula", "Uygulama arka plana geçerken"),
    ("kus_dikkat", 1004199, 2.0, "Bıldırcın", "Coturnix coturnix", "Dikkat bildirimi"),
    ("kus_yasak", 999018, 2.2, "Saksağan", "Pica pica", "Yasak alan bildirimi"),
]
SR = 44_100
UA = {"User-Agent": "AvHaritasi-ses-araci/1.0 (kisisel, ticari olmayan)"}


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read()


def metadata(xc):
    page = fetch(f"https://xeno-canto.org/{xc}").decode("utf-8", "replace")
    lic = re.search(r"creativecommons\.org/licenses/([a-z-]+)/([0-9.]+)", page)
    if not lic:
        raise SystemExit(f"XC{xc}: lisans bulunamadı")
    rec = re.search(r"class=['\"]jp-xc-recordist['\"]>([^<]+)", page)
    return {
        "license": f"CC {lic.group(1).upper()} {lic.group(2)}",
        "licenseUrl": f"https://creativecommons.org/licenses/{lic.group(1)}/{lic.group(2)}/",
        "recordist": html.unescape(rec.group(1)).strip() if rec else "?",
        "url": f"https://xeno-canto.org/{xc}",
    }


def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, np.float32)


def best_window(x, dur):
    n = int(dur * SR)
    if len(x) <= n:
        return x
    # 2-10 kHz bandına yakın enerji: düşük frekanslı rüzgâr/trafik gürültüsünü bastırmak için türev
    e = np.convolve(np.abs(np.diff(x, prepend=0)), np.ones(n), "valid")
    i = int(np.argmax(e))
    return x[i:i + n]


def finish(x):
    x = x - np.mean(x)
    fade = int(0.08 * SR)
    ramp = np.linspace(0, 1, fade)
    x[:fade] *= ramp
    x[-fade:] *= ramp[::-1]
    peak = np.max(np.abs(x)) or 1
    return (x / peak * 0.85 * 32767).astype(np.int16)


def write_wav(path, pcm):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", "-",
                    "-c:a", "pcm_s16le", path], input=pcm.tobytes(), check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--verify", action="store_true", help="BirdNET ile türü doğrula")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    credits = []
    for name, xc, dur, tr, sci, use in SOUNDS:
        meta = metadata(xc)
        if "ND" in meta["license"]:
            raise SystemExit(f"XC{xc}: {meta['license']} — türev (kırpma) yasak, başka kayıt seçin")
        with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
            tmp.write(fetch(f"https://xeno-canto.org/{xc}/download"))
            tmp.flush()
            x = decode(tmp.name)
        clip = finish(best_window(x, dur))
        path = os.path.join(a.out, name + ".wav")
        write_wav(path, clip)
        credits.append({"file": name + ".wav", "species": tr, "scientific": sci, "use": use,
                        "xc": f"XC{xc}", **meta, "note": "Kırpıldı, ses düzeyi normalleştirildi."})
        print(f"{path}: {len(clip) / SR:.1f} sn, {meta['license']}, {meta['recordist']}")
    with open(os.path.join(a.out, "kus_sesleri_kunye.json"), "w") as f:
        json.dump(credits, f, ensure_ascii=False, indent=2)

    if a.verify:
        from birdnetlib import Recording
        from birdnetlib.analyzer import Analyzer
        an = Analyzer()
        for c in credits:
            # BirdNET 3 sn'lik pencere ister: kısa klibi sessizlikle 3 sn'ye tamamla
            p = os.path.join(a.out, c["file"])
            with tempfile.NamedTemporaryFile(suffix=".wav") as t:
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", p, "-af", "apad=whole_dur=3", "-ar", "48000", t.name], check=True)
                r = Recording(an, t.name, min_conf=0.1)
                r.analyze()
            top = sorted(r.detections, key=lambda d: -d["confidence"])[:2]
            ok = any(d["scientific_name"] == c["scientific"] for d in top)
            print(("✓" if ok else "✗"), c["file"], [(d["scientific_name"], round(d["confidence"], 2)) for d in top])


if __name__ == "__main__":
    sys.exit(main())
