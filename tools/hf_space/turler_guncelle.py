#!/usr/bin/env python3
"""turler.json'u uygulamanın BirdNET İstanbul tür listesinden yeniden üretir.

Kullanım (depo kökünden): python3 tools/hf_space/turler_guncelle.py
"""
import json
from pathlib import Path

KOK = Path(__file__).resolve().parents[2]
KAYNAK = KOK / "ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json"
HEDEF = Path(__file__).with_name("turler.json")

turler = [{k: s[k] for k in ("sci", "en", "tr")} for s in json.loads(KAYNAK.read_text())["species"]]
HEDEF.write_text(json.dumps(turler, ensure_ascii=False, indent=1) + "\n")
print(f"{len(turler)} tür yazıldı → {HEDEF.relative_to(KOK)}")
