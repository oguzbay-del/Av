# Fotoğraftan kuş tanıma modeli (BirdClassifier.mlpackage)

`ios/AvHaritasi/BirdPhoto/BirdClassifier.mlpackage` uygulamaya gömülüdür (20,6 MB, int8 ağırlık). Fotoğraf
önce telefonda bu modelle tanınır; model emin olmazsa (en olası tür < %50) ve internet varsa çevrimiçi
BioCLIP 2'ye sorulur (tools/kus_sunucu).

## Model

| | |
|---|---|
| Mimari | EfficientNetV2-S (ImageNet-21k ön eğitimli), 320×320 giriş, ince ayar |
| Türler | 331 İstanbul türü (`BirdNET_Istanbul_Weeks.json`; Puhu ve Sığır Balıkçılı için serbest lisanslı fotoğraf bulunamadı) |
| Veri | iNaturalist araştırma düzeyi gözlemler, CC0 / CC BY / CC BY-NC, 130.554 fotoğraf (önce Türkiye, sonra Avrupa) |
| Eğitim | Kaggle T4, 20 tur, karıştırma (mixup/cutmix), EMA, dengeli örnekleme, sıcaklık ayarı (`tools/kus_foto`) |

## Sonuçlar (eğitimde hiç kullanılmamış 13.037 test fotoğrafı)

| Ölçü | Değer |
|---|---|
| İlk tahmin doğru | %81,8 |
| İlk 3'ten biri doğru | %91,4 |
| Model ≥ %70 eminken doğruluk | %93,3 (fotoğrafların %79'u) |
| Avlanamayan kuşun av türü sanılması (≥ %70 güvenle) | %0,43 |
| int8 sıkıştırma kaybı | 0 puan; Core ML ↔ PyTorch uyuşması %99 (macOS, `kus-foto-dogrula.yml`) |

Zor koşullarda ilk tahmin: eğik %78, karanlık %76, düşük kaliteli JPEG %71, düşük çözünürlük %70,
uzak kuş %63, bulanık %57. Ayrıntı: `docs/kus_foto/` (metrikler, tür bazında başarı, karışıklıklar, eğitim geçmişi).

## Yeniden üretme

Kaggle'da iki betik: `tools/kus_foto/kaggle/veri` (GPU'suz, fotoğrafları indirir) ve `tools/kus_foto/kaggle`
(GPU, eğitim + değerlendirme + Core ML). Colab için `tools/kus_foto/kus_foto_colab.ipynb`. Sonra paketi
`kus-foto-dogrula.yml` ile macOS'ta doğrulayın.

Arayüz: girdi `image` (RGB, 320×320, Vision `centerCrop`); çıktılar `classLabel` ve `classLabelProbs`.
Sınıf adları `Bilimsel ad_İngilizce ad`; yasal durum için MAK'taki ada `IstanbulSpecies.lawName` ile çevrilir.

## Lisans ve künye

Eğitim fotoğraflarının bir kısmı CC BY-NC olduğundan model yalnızca ticari olmayan kullanım içindir.
Fotoğraf sahipleri ve lisansları: `docs/kus_foto/kunye.csv.gz` (sınıf, fotoğraf, sahip, lisans, gözlem bağlantısı).
