## Özet

<!-- Ne değişti, neden? -->

## Denetim listesi

- [ ] Çeviri: `python3 tools/l10n.py && python3 tools/l10n.py --check` → 0 eksik / 0 kullanılmayan
- [ ] Kılavuz güncellendi (gerekirse): `ios/AvHaritasi/Help/Kilavuz.json` + `python3 tools/kilavuz.py`
- [ ] Kuş tanıma akış şeması güncellendi (gerekirse): `docs/KUS_FOTO_MODELI.md` + `python3 tools/akis_denetim.py`
- [ ] Gizlilik etkisi varsa `docs/GIZLILIK.md`, `docs/PRIVACY.md`, `docs/YAYIN.md` (ve gerekirse `PrivacyInfo.xcprivacy`)
- [ ] Saf karar mantığı değiştiyse birim testi eklendi/güncellendi
- [ ] CI yeşil (ios-build, lint)
