#!/usr/bin/env python3
"""Kuş tanıma akış şeması denetimi.

docs/KUS_FOTO_MODELI.md "Akış şeması" bölümündeki `<!-- akis-sabitleri: ad=değer ... -->` yorumunu
Swift kaynaklarındaki sabitlerle, BirdNET tür listesiyle ve fotoğraf modelinin sınıf sayısıyla karşılaştırır.
Fark varsa dosya ve sabit adını söyleyerek hata verir (CI: lint.yml).

Kullanım: python3 tools/akis_denetim.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

KOK = Path(__file__).resolve().parent.parent
BELGE = KOK / "docs/KUS_FOTO_MODELI.md"
FOTO = "ios/AvHaritasi/BirdPhoto"
ONLINE = f"{FOTO}/Domain/OnlineBirdID.swift"
BULUCU = f"{FOTO}/Domain/BirdDetection.swift"
MEVSIM = f"{FOTO}/Domain/SeasonalPrior.swift"
VIDEO = f"{FOTO}/Domain/VideoBirdID.swift"
BIRDNET = "ios/AvHaritasi/BirdNET/BirdNETOnDevice.swift"
TURLER = "ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json"
SINIFLANDIRICI = f"{FOTO}/BirdClassifier.mlpackage/Data/com.apple.CoreML/model.mlmodel"

# Belgedeki ad → (dosya, tür adı, sabit adı)
SWIFT_SABITLERI: dict[str, tuple[str, str, str]] = {
    "cevrimici_esik": (ONLINE, "OnlineBirdID", "uncertainBelow"),
    "cevrimici_foto_px": (ONLINE, "OnlineBirdID", "photoMaxSide"),
    "cevrimici_ses_en_az_sn": (ONLINE, "OnlineBirdID", "soundMinSeconds"),
    "cevrimici_ses_en_cok_sn": (ONLINE, "OnlineBirdID", "soundMaxSeconds"),
    "bulucu_esik": (BULUCU, "DetectionDecoder", "defaultThreshold"),
    "bulucu_en_cok": (BULUCU, "DetectionDecoder", "maxBirds"),
    "bulucu_pay": (BULUCU, "DetectionDecoder", "padding"),
    "birdnet_hz": (BIRDNET, "BirdNETOnDevice", "sampleRate"),
    "mevsim_taban": (MEVSIM, "SeasonalPrior", "floor"),
    "mevsim_hafta": (MEVSIM, "SeasonalPrior", "spread"),
    "video_tarama_sn": (VIDEO, "VideoWindowSelector", "maxDuration"),
    "video_tarama_fps": (VIDEO, "VideoWindowSelector", "scanFPS"),
    "video_pencere_sn": (VIDEO, "VideoWindowSelector", "window"),
    "video_pencere_fps": (VIDEO, "VideoWindowSelector", "windowFPS"),
    "video_kare": (VIDEO, "VideoWindowSelector", "bestFrameCount"),
}
DIGER = {
    "birdnet_tur": f"{TURLER} (species sayısı)",
    "tur_sayisi": f"{SINIFLANDIRICI} (sınıf etiketi sayısı)",
}


def belge_sabitleri() -> dict[str, float]:
    m = re.search(r"<!--\s*akis-sabitleri:(.*?)-->", BELGE.read_text(encoding="utf-8"), re.S)
    if not m:
        sys.exit(f"HATA: {BELGE.relative_to(KOK)} içinde '<!-- akis-sabitleri: ... -->' yorumu yok.")
    out: dict[str, float] = {}
    for parca in m.group(1).split():
        ad, _, deger = parca.partition("=")
        try:
            out[ad] = float(deger)
        except ValueError:
            sys.exit(f"HATA: akis-sabitleri içinde sayı olmayan değer: {parca}")
    return out


def swift_sabiti(dosya: str, tur: str, ad: str) -> float:
    """`enum/struct <tur> { ... static let <ad> = <sayı> ... }` içinden sayıyı okur."""
    metin = (KOK / dosya).read_text(encoding="utf-8")
    bas = re.search(rf"^(?:enum|struct|actor|final class|class)\s+{tur}\b[^{{]*\{{", metin, re.M)
    if not bas:
        raise LookupError(f"{dosya}: '{tur}' tanımı bulunamadı")
    # Türün gövdesi: süslü parantezleri sayarak kapanışa kadar
    derinlik, i = 0, bas.end() - 1
    for i in range(bas.end() - 1, len(metin)):
        if metin[i] == "{":
            derinlik += 1
        elif metin[i] == "}":
            derinlik -= 1
            if derinlik == 0:
                break
    govde = metin[bas.end():i]
    m = re.search(rf"^\s*static let {ad}(?:\s*:\s*\w+\??)?\s*=\s*([0-9_.]+)\s*$", govde, re.M)
    if not m:
        raise LookupError(f"{dosya}: '{tur}.{ad}' sabit sayı olarak ('static let {ad} = <sayı>') bulunamadı")
    return float(m.group(1).replace("_", ""))


def birdnet_tur_sayisi() -> int:
    return len(json.loads((KOK / TURLER).read_text(encoding="utf-8"))["species"])


def siniflandirici_tur_sayisi() -> int:
    """model.mlmodel (protobuf) içindeki 'Bilimsel ad_İngilizce ad' sınıf etiketleri (uzunluk önekli dizgiler)."""
    veri = (KOK / SINIFLANDIRICI).read_bytes()
    desen = re.compile(rb"\x0a([\x05-\x7f])([A-Z][a-z]+ [a-z-]+[^\x00-\x1f_]*_[^\x00-\x1f]+?)(?=[\x0a\x12\x1a\x22])")
    return len({m.group(2) for m in desen.finditer(veri) if len(m.group(2)) == m.group(1)[0]})


def main() -> int:
    belge = belge_sabitleri()
    hatalar: list[str] = []
    bilinen = set(SWIFT_SABITLERI) | set(DIGER)
    for ad in sorted(set(belge) - bilinen):
        hatalar.append(f"akis-sabitleri içinde bilinmeyen ad '{ad}' (tools/akis_denetim.py'ye ekleyin ya da silin)")
    for ad in sorted(bilinen - set(belge)):
        hatalar.append(f"akis-sabitleri içinde '{ad}' eksik")

    gercek: dict[str, tuple[float, str]] = {}
    for ad, (dosya, tur, sabit) in SWIFT_SABITLERI.items():
        try:
            gercek[ad] = (swift_sabiti(dosya, tur, sabit), f"{dosya} › {tur}.{sabit}")
        except (LookupError, OSError) as e:
            hatalar.append(str(e))
    try:
        gercek["birdnet_tur"] = (birdnet_tur_sayisi(), DIGER["birdnet_tur"])
    except (OSError, KeyError, ValueError) as e:
        hatalar.append(f"{TURLER} okunamadı: {e}")
    try:
        gercek["tur_sayisi"] = (siniflandirici_tur_sayisi(), DIGER["tur_sayisi"])
    except OSError as e:
        hatalar.append(f"{SINIFLANDIRICI} okunamadı: {e}")

    for ad, (deger, kaynak) in gercek.items():
        if ad in belge and abs(belge[ad] - deger) > 1e-9:
            hatalar.append(f"{kaynak} = {deger:g}, ama docs/KUS_FOTO_MODELI.md akis-sabitleri '{ad}={belge[ad]:g}'")

    if hatalar:
        print("Kuş tanıma akış şeması kodla uyuşmuyor:")
        for h in hatalar:
            print(f"  - {h}")
        print("Akış değiştiyse docs/KUS_FOTO_MODELI.md 'Akış şeması' (şema, adımlar ve akis-sabitleri) güncellenmeli.")
        return 1
    print(f"Akış şeması güncel: {len(gercek)} sabit kodla aynı.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
