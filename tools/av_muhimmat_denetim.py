#!/usr/bin/env python3
"""Av mühimmatı bilgi tablosu denetimi (yalnızca standart kütüphane).

ios/AvHaritasi/Hunting/Data/AvMuhimmat.json dosyasını denetler:
- şema: üst düzey anahtarlar, tür alanları, tipler;
- MAK 2026-27'de İstanbul'da avlanabilir her tür (kus1, kus3, kus4, memeli1, memeli2_domuz grupları;
  il yasağı olan keklik grubu hariç) tabloda tam bir kez var, keklik grubu yok, grup kimlikleri MAK ile aynı;
- saçma numaraları shotSizes'ta, şevrotin kimlikleri buckshot'ta var;
- şoklar 1..5 (tek kurşunda ayrıca "paradoks"); çelik şoku steel.maxChokeId'den dar değil;
- kaynak kimlikleri sources'ta tanımlı; confidence=high türlerde kaynak listesi boş değil;
- tek kurşun yalnızca yaban domuzunda; domuzda saçma yok.

Kullanım: python3 tools/av_muhimmat_denetim.py   (hata varsa çıkış kodu 1)
"""
import json
import pathlib
import sys

KOK = pathlib.Path(__file__).resolve().parent.parent
TABLO = KOK / "ios/AvHaritasi/Hunting/Data/AvMuhimmat.json"
MAK = KOK / "ios/AvHaritasi/MapData/mak_2026_2027.json"

GRUPLAR = {"kus1", "kus3", "kus4", "memeli1", "memeli2_domuz"}
UST_ANAHTARLAR = {"schemaVersion", "title", "updated", "disclaimer", "numbering", "sources", "shotSizes",
                  "buckshot", "chokes", "paradox", "steel", "legal", "terrains", "species"}
TUR_ANAHTARLARI = {"name", "latin", "group", "category", "sizeClass", "weightG", "distanceM", "terrains",
                   "shotAllowed", "leadShot", "steelShot", "loadGrams12", "loadGrams20", "choke", "gauges",
                   "minGauge", "magnumNeeded", "buckshot", "slug", "rifle", "aim", "maxEthicalRangeM", "notes",
                   "sources", "confidence"}
KALIBRELER = {"10", "12", "16", "20", "24", "28", "32", ".410"}
GUVEN = {"high", "medium", "low"}
SLUG_TURU = "Yaban domuzu"

hatalar = []


def hata(msg):
    hatalar.append(msg)


def aralik(deger, ad):
    if not (isinstance(deger, list) and len(deger) == 2 and all(isinstance(x, (int, float)) for x in deger)
            and deger[0] <= deger[1]):
        hata(f"{ad}: [en az, en çok] sayı çifti olmalı: {deger!r}")


def main():
    d = json.loads(TABLO.read_text(encoding="utf-8"))
    mak = json.loads(MAK.read_text(encoding="utf-8"))

    eksik = UST_ANAHTARLAR - d.keys()
    if eksik:
        hata(f"Üst düzey anahtar eksik: {sorted(eksik)}")
        return

    kaynaklar = d["sources"]
    if not isinstance(kaynaklar, dict) or not kaynaklar:
        hata("sources boş olmayan bir sözlük olmalı")
        kaynaklar = {}

    def kaynak_denetle(liste, ad, zorunlu=False):
        if not isinstance(liste, list):
            hata(f"{ad}: sources liste olmalı")
            return
        if zorunlu and not liste:
            hata(f"{ad}: kaynak listesi boş")
        for k in liste:
            if k not in kaynaklar:
                hata(f"{ad}: tanımsız kaynak kimliği {k!r}")

    # Saçma tablosu
    sacma = {}
    onceki = None
    for s in d["shotSizes"]:
        sid = s.get("id")
        if sid in sacma:
            hata(f"shotSizes: yinelenen numara {sid!r}")
        sacma[sid] = s
        mm = s.get("mm")
        if not isinstance(mm, (int, float)) or not 1.0 <= mm <= 5.0:
            hata(f"shotSizes {sid}: mm 1–5 arasında olmalı")
            continue
        aralik(s.get("mmRange"), f"shotSizes {sid} mmRange")
        if onceki is not None and mm >= onceki:
            hata(f"shotSizes {sid}: tablo iriden küçüğe sıralı olmalı")
        onceki = mm
    sevrotin = {b.get("id") for b in d["buckshot"]}

    # Şoklar
    sok_idleri = sorted(c.get("id") for c in d["chokes"])
    if sok_idleri != [1, 2, 3, 4, 5]:
        hata(f"chokes: kimlikler tam olarak 1..5 olmalı, bulunan {sok_idleri}")
    for c in d["chokes"]:
        aralik(c.get("constrictionMm"), f"chokes {c.get('id')} constrictionMm")
        aralik(c.get("effectiveRangeM"), f"chokes {c.get('id')} effectiveRangeM")
    celik_en_dar = d["steel"].get("maxChokeId")
    if celik_en_dar not in (1, 2, 3, 4, 5):
        hata("steel.maxChokeId 1..5 olmalı")
        celik_en_dar = 3
    kaynak_denetle(d["steel"].get("sources", []), "steel", zorunlu=True)
    kaynak_denetle(d["paradox"].get("sources", []), "paradox")

    # Yasal bilgiler
    for y in d["legal"]:
        ad = f"legal {y.get('id')}"
        if not isinstance(y.get("verified"), bool):
            hata(f"{ad}: verified true/false olmalı")
        if not y.get("fact") or not y.get("ref"):
            hata(f"{ad}: fact ve ref zorunlu")
        kaynak_denetle(y.get("sources", []), ad, zorunlu=True)

    araziler = {t.get("id") for t in d["terrains"]}
    for t in d["terrains"]:
        aralik(t.get("distanceM"), f"terrains {t.get('id')} distanceM")

    # MAK: İstanbul'da avlanabilir türler
    yasak = set(mak.get("provinceBannedSpecies", []))
    beklenen = {}
    for g in mak["groups"]:
        for ad in g["species"]:
            if ad in yasak:
                continue
            if g["id"] not in GRUPLAR:
                hata(f"MAK'ta beklenmeyen avlanabilir grup {g['id']} ({ad}); denetimi güncelleyin")
                continue
            beklenen[ad] = g["id"]
    keklik = {ad for g in mak["groups"] for ad in g["species"] if ad in yasak}
    korunan = set(mak.get("protectedLatin", {}) or {})

    gorulen = {}
    for s in d["species"]:
        ad = s.get("name", "?")
        eksik_alan = TUR_ANAHTARLARI - s.keys()
        if eksik_alan:
            hata(f"{ad}: eksik alan {sorted(eksik_alan)}")
            continue
        if ad in gorulen:
            hata(f"{ad}: yinelenen tür")
        gorulen[ad] = s
        if ad in keklik:
            hata(f"{ad}: İstanbul'da yasak (keklik grubu) — tabloda olmamalı")
        if s["latin"] in korunan:
            hata(f"{ad}: korunan tür ({s['latin']})")
        if ad in beklenen and s["group"] != beklenen[ad]:
            hata(f"{ad}: grup {s['group']} ama MAK'ta {beklenen[ad]}")
        if s["category"] not in ("kuş", "memeli"):
            hata(f"{ad}: category kuş/memeli olmalı")
        if s["category"] == "kuş" and not s["group"].startswith("kus"):
            hata(f"{ad}: kuş ama grup {s['group']}")
        if s["confidence"] not in GUVEN:
            hata(f"{ad}: confidence high/medium/low olmalı")
        kaynak_denetle(s["sources"], ad, zorunlu=s["confidence"] == "high")
        aralik(s["distanceM"], f"{ad} distanceM")
        aralik(s["weightG"], f"{ad} weightG")
        aralik(s["loadGrams12"], f"{ad} loadGrams12")
        if s["loadGrams20"] is not None:
            aralik(s["loadGrams20"], f"{ad} loadGrams20")
        for t in s["terrains"]:
            if t not in araziler:
                hata(f"{ad}: bilinmeyen arazi {t!r}")
        if not s["gauges"] or not set(s["gauges"]) <= KALIBRELER:
            hata(f"{ad}: geçersiz kalibre listesi {s['gauges']}")
        if s["minGauge"] not in s["gauges"]:
            hata(f"{ad}: minGauge {s['minGauge']} gauges içinde değil")
        if not isinstance(s["maxEthicalRangeM"], (int, float)) or s["maxEthicalRangeM"] <= 0:
            hata(f"{ad}: maxEthicalRangeM pozitif sayı olmalı")
        if not s["aim"]:
            hata(f"{ad}: aim (nişan/etik not) boş")

        if s["shotAllowed"]:
            for tip in ("leadShot", "steelShot"):
                blok = s[tip]
                if not blok:
                    hata(f"{ad}: {tip} eksik")
                    continue
                for no in [blok["primary"], *blok["alternatives"]]:
                    if no not in sacma:
                        hata(f"{ad}: {tip} numarası {no!r} shotSizes'ta yok")
                    elif tip == "leadShot" and sacma[no].get("steelOnly"):
                        hata(f"{ad}: {no!r} yalnızca çelik numarası, kurşunda kullanılamaz")
            ch = s["choke"]
            if not ch:
                hata(f"{ad}: choke eksik")
            else:
                for k in ("first", "second", "steelFirst", "steelSecond"):
                    if ch.get(k) not in (1, 2, 3, 4, 5):
                        hata(f"{ad}: choke.{k} 1..5 olmalı")
                for k in ("steelFirst", "steelSecond"):
                    if ch.get(k) in (1, 2, 3, 4, 5) and ch[k] < celik_en_dar:
                        hata(f"{ad}: choke.{k}={ch[k]} çelik için {celik_en_dar}'ten dar")
        else:
            if s["leadShot"] or s["steelShot"] or s["buckshot"]:
                hata(f"{ad}: shotAllowed=false iken saçma/şevrotin önerilemez")
        if s["buckshot"]:
            for b in s["buckshot"]["ids"]:
                if b not in sevrotin:
                    hata(f"{ad}: şevrotin {b!r} buckshot tablosunda yok")
        if s["slug"]:
            if ad != SLUG_TURU:
                hata(f"{ad}: tek kurşun yalnızca yaban domuzunda önerilir")
            for c in s["slug"].get("chokes", []):
                if c not in (4, 5, "paradoks"):
                    hata(f"{ad}: tek kurşun şoku {c!r} (yalnızca 5, 4, paradoks)")
        if s["rifle"] and s["group"] not in ("memeli1", "memeli2_domuz"):
            hata(f"{ad}: yivli kuşta yasak (MAK 10/1-ğ)")
        if s["rifle"] and ad == "Yaban tavşanı":
            hata(f"{ad}: yivli tavşanda yasak (MAK 10/1-ğ)")

    for ad in beklenen:
        if ad not in gorulen:
            hata(f"Eksik tür: {ad} ({beklenen[ad]})")
    for ad in gorulen:
        if ad not in beklenen and ad not in keklik:
            hata(f"MAK'ta İstanbul için avlanabilir olmayan tür: {ad}")
    domuz = gorulen.get(SLUG_TURU)
    if domuz and (domuz["shotAllowed"] or not domuz["slug"]):
        hata("Yaban domuzu: shotAllowed=false ve slug zorunlu (MAK 10/1-ı)")

    print(f"{len(gorulen)} tür, {len(sacma)} saçma numarası, {len(d['legal'])} yasal bilgi denetlendi.")


if __name__ == "__main__":
    main()
    if hatalar:
        print(f"{len(hatalar)} hata:")
        for h in hatalar:
            print(" -", h)
        sys.exit(1)
    print("Tamam.")
