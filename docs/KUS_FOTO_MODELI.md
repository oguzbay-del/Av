# Fotoğraftan kuş tanıma modeli (BirdClassifier.mlmodel)

`ios/AvHaritasi/BirdPhoto/` altına `BirdClassifier.mlmodel` konduğunda Xcode onu derleyip uygulamaya ekler; fotoğraftan
tanıma tür düzeyinde çalışır. Model yoksa uygulama Apple Vision'ın genel sınıflandırmasıyla
(ördek, kaz, baykuş...) çalışır.

Model üretimi: GitHub Actions › **Kuş fotoğraf modeli** › Run workflow. Yapıtta model, metrikler
(`metrikler.json`, `tur_basari.csv`, `karisiklik.csv`) ve eğitim fotoğraflarının künyesi
(`kunye.csv`) bulunur. Yerelde: `python3 tools/fetch_bird_photos.py veri/kus_foto` ardından
`swift tools/train_bird_classifier.swift veri/kus_foto cikti` (macOS 14+).

Beklenen arayüz: girdi görüntü; çıktılar `classLabel` (String) ve `classLabelProbs`
(String → Double). Sınıf adları `Bilimsel ad_İngilizce ad` biçiminde olmalı (MAK yasal durum
eşleşmesi bilimsel adla yapılır).

Lisans: eğitim fotoğrafları CC0 / CC BY / CC BY-NC → model yalnızca ticari olmayan kullanım içindir.
