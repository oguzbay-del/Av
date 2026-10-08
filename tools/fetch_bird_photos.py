#!/usr/bin/env python3
"""Kuş fotoğrafı tür modeli için eğitim verisi: iNaturalist "araştırma düzeyi" gözlemleri.

Tür listesi MAK 2026-27'den gelir: avına izin verilen (EK-2) ve koruma altındaki (EK-1) kuşlar.
Yalnızca serbest lisanslı fotoğraflar (CC0, CC BY, CC BY-NC) indirilir; her fotoğrafın
sahibi ve lisansı kunye.csv'ye yazılır (CC BY atfı için).

Önce Türkiye gözlemleri, yetmezse Avrupa ve Batı Asya'dan tamamlanır.
Klasör yapısı Create ML'in beklediği gibidir:  <cikti>/<Bilimsel ad>_<İngilizce ad>/<id>.jpg

  python3 tools/fetch_bird_photos.py veri/kus_foto --per-species 150
Gerekli: requests
"""
import argparse
import csv
import json
import os
import sys
import time

import requests

API = "https://api.inaturalist.org/v1"
LICENSES = "cc0,cc-by,cc-by-nc"
PLACES = [("Türkiye", 7183), ("Avrupa", 97391), (None, None)]  # son çare: tüm dünya
UA = {"User-Agent": "AvHaritasi-egitim/1.0 (github.com/oguzbay-del/Av)"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def species_list():
    mak = json.load(open(os.path.join(ROOT, "ios", "AvHaritasi", "MapData", "mak_2026_2027.json"), encoding="utf-8"))
    names = dict(mak.get("huntableLatin", {}))
    names.update(mak.get("protectedLatin", {}))
    return sorted(names.items())


def get(url, params, tries=4):
    for i in range(tries):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=30)
            if r.status_code == 429:
                time.sleep(10 * (i + 1))
                continue
            r.raise_for_status()
            return r.json()
        except requests.RequestException as e:
            if i == tries - 1:
                raise
            print("  yeniden deneniyor:", e, file=sys.stderr)
            time.sleep(2 ** i)


def taxon(sci):
    """Kuş (Aves) değilse ya da bulunamazsa None."""
    res = get(f"{API}/taxa", {"q": sci, "rank": "species,subspecies", "per_page": 5})["results"]
    for t in res:
        if t["name"].lower() == sci.lower() and t.get("iconic_taxon_name") == "Aves":
            return t
    return None


def observations(taxon_id, place_id, need, seen):
    page = 1
    while need > 0 and page <= 5:
        params = {"taxon_id": taxon_id, "quality_grade": "research", "photo_license": LICENSES,
                  "photos": "true", "per_page": 100, "page": page, "order_by": "votes"}
        if place_id:
            params["place_id"] = place_id
        data = get(f"{API}/observations", params)
        time.sleep(1.0)  # iNaturalist isteği: saniyede en fazla ~1 istek
        results = data.get("results", [])
        if not results:
            return
        for obs in results:
            # Gözlem başına bir fotoğraf: aynı kuşun art arda kareleri eğitimi/testi bozmasın
            for ph in obs.get("photos", [])[:1]:
                if ph["id"] in seen or (ph.get("license_code") or "").lower() not in LICENSES.split(","):
                    continue
                seen.add(ph["id"])
                need -= 1
                yield obs, ph
                break
            if need <= 0:
                return
        page += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--per-species", type=int, default=150)
    ap.add_argument("--min", type=int, default=40, help="bundan az fotoğrafı olan tür eğitime alınmaz")
    ap.add_argument("--only", help="virgülle ayrılmış bilimsel adlar (deneme için)")
    args = ap.parse_args()
    only = {x.strip().lower() for x in args.only.split(",")} if args.only else None
    os.makedirs(args.out, exist_ok=True)

    credits = open(os.path.join(args.out, "kunye.csv"), "w", newline="", encoding="utf-8")
    w = csv.writer(credits)
    w.writerow(["sinif", "fotograf", "sahip", "lisans", "gozlem"])
    summary = []
    for sci, tr in species_list():
        if only and sci.lower() not in only:
            continue
        t = taxon(sci)
        time.sleep(1.0)
        if not t:
            print(f"- {sci} ({tr}): kuş değil ya da bulunamadı, atlandı")
            continue
        common = (t.get("preferred_common_name") or sci).replace("/", "-").replace("_", " ")
        label = f"{t['name']}_{common}"
        d = os.path.join(args.out, label)
        os.makedirs(d, exist_ok=True)
        have = len([f for f in os.listdir(d) if f.endswith(".jpg")])
        seen = set()
        for place, pid in PLACES:
            need = args.per_species - have
            if need <= 0:
                break
            for obs, ph in observations(t["id"], pid, need, seen):
                path = os.path.join(d, f"{ph['id']}.jpg")
                if not os.path.exists(path):
                    url = ph["url"].replace("/square.", "/medium.")  # ~500 px
                    try:
                        r = requests.get(url, headers=UA, timeout=30)
                        r.raise_for_status()
                        open(path, "wb").write(r.content)
                    except requests.RequestException as e:
                        print("  indirilemedi:", url, e, file=sys.stderr)
                        continue
                    have += 1
                w.writerow([label, ph["id"], obs.get("user", {}).get("login", ""), ph.get("license_code", ""),
                            f"https://www.inaturalist.org/observations/{obs['id']}"])
        if have < args.min:
            print(f"- {label}: yalnızca {have} fotoğraf (<{args.min}), eğitimden çıkarıldı")
            for f in os.listdir(d):
                os.remove(os.path.join(d, f))
            os.rmdir(d)
            continue
        summary.append((label, tr, have))
        print(f"+ {label} ({tr}): {have}")
    credits.close()
    json.dump([{"label": l, "turkish": tr, "count": n} for l, tr, n in summary],
              open(os.path.join(args.out, "siniflar.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(summary)} tür, {sum(n for *_, n in summary)} fotoğraf")


if __name__ == "__main__":
    main()
