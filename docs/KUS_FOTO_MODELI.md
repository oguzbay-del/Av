# Fotoğraftan kuş tanıma modeli (BirdClassifier.mlpackage)

`ios/AvHaritasi/BirdPhoto/BirdClassifier.mlpackage` uygulamaya gömülüdür (20,6 MB, int8 ağırlık). Fotoğraf
önce telefonda bu modelle tanınır; model emin olmazsa (en olası tür < %50) ve internet varsa çevrimiçi
BioCLIP 2'ye sorulur (tools/kus_sunucu).

## Model

| | |
|---|---|
| Mimari | EfficientNetV2-S (ImageNet-21k ön eğitimli), 384×384 giriş, ince ayar |
| Türler | 331 İstanbul türü (`BirdNET_Istanbul_Weeks.json`; Puhu ve Sığır Balıkçılı için serbest lisanslı fotoğraf bulunamadı) |
| Veri | iNaturalist araştırma düzeyi gözlemler, CC0 / CC BY / CC BY-NC, 130.554 fotoğraf (önce Türkiye, sonra Avrupa) |
| Eğitim | Kaggle 2×T4 (DDP), 30 tur, BioCLIP 2 damıtma, bulanıklık/uzaklık artırımı, karıştırma (mixup/cutmix), EMA, dengeli örnekleme, sıcaklık ayarı (`tools/kus_foto`) |

## Sonuçlar (eğitimde hiç kullanılmamış 13.037 test fotoğrafı)

| Ölçü | Değer |
|---|---|
| İlk tahmin doğru | %84,6 (önceki model %81,8) |
| İlk 3'ten biri doğru | %93,4 (önceki %91,4) |
| Model ≥ %70 eminken doğruluk | %96,1 (fotoğrafların %78'i) |
| Avlanamayan kuşun av türü sanılması (≥ %70 güvenle) | %0,21 (önceki %0,43) |
| int8 sıkıştırma kaybı | 0,02 puan; Core ML ↔ PyTorch uyuşması %98,5 (macOS, `kus-foto-dogrula.yml`) |

Zor koşullarda ilk tahmin (önceki model parantez içinde): düşük çözünürlük %82 (%70), eğik %82 (%78),
karanlık %80 (%76), bulanık %79 (%57), düşük kaliteli JPEG %78 (%71), uzak kuş %72 (%63).
Ayrıntı: `docs/kus_foto/` (metrikler, tür bazında başarı, karışıklıklar, eğitim geçmişi).

## Yeniden üretme

Kaggle'da iki betik: `tools/kus_foto/kaggle/veri` (GPU'suz, fotoğrafları indirir) ve `tools/kus_foto/kaggle`
(GPU, eğitim + değerlendirme + Core ML). Colab için `tools/kus_foto/kus_foto_colab.ipynb`. Sonra paketi
`kus-foto-dogrula.yml` ile macOS'ta doğrulayın.

Eğitim tarifi (`kus_foto.py` varsayılanları; Kaggle T4 ×2, ölçülen: 143 görüntü/sn, tur başına 13,5 dk, toplam ~7 sa):

- **İki GPU (DDP):** `egit` her GPU'ya bir süreç açar (`torchrun`; `GPUS=1` eski tek GPU yolu). Ağırlıklı
  örnekleme (1/√n) tüm süreçlerde aynı tohumla çekilip dilimlenir; EMA, doğrulama ve kayıt yalnızca 0. süreçte.
  Kaggle betiği önce kısa bir hız denemesi yapar; DDP başarısız ya da tek GPU'dan belirgin hızlı değilse tek GPU
  ile sürer ve tur sayısını 12 saatlik oturuma sığdırır (`cikti/hiz.json`).
- **384 px, 30 tur** (eğitim ve değerlendirme 384). Diskteki fotoğrafların kısa kenarı 368 px (veri betiği
  320 px için indirdi); 384'e hafif büyütme yeniden indirmeye değmez.
- **Uzak/telefon fotoğrafı benzetimi** (GPU'da): rastgele Gauss bulanıklığı, küçültüp büyütme, uzaklaştırma.
- **BioCLIP 2 damıtma:** `ogretmen` adımı eğitim fotoğraflarının BioCLIP 2 sıfır-atış olasılıklarını bir kez
  hesaplar (sunucudaki metin şablonları, ~25 dk; doğrulamada %86,7); eğitimde KL kaybı (ağırlık 0,5, sıcaklık 2). Öğretmenin
  doğrulama doğruluğu %50'nin altındaysa damıtma kendiliğinden kapanır (`KD=0` ile de kapatılır).
- Model yine EfficientNetV2-S (int8 Core ML ~21 MB); sıcaklık ayarı, EMA, güvenlik ölçüsü ve Core ML adımları aynı.

Arayüz: girdi `image` (RGB, 384×384, Vision `centerCrop`); çıktılar `classLabel` ve `classLabelProbs`.
Sınıf adları `Bilimsel ad_İngilizce ad`; yasal durum için MAK'taki ada `IstanbulSpecies.lawName` ile çevrilir.

## Kuş bulucu (BirdDetector.mlpackage)

Tür modeli kuşun kadrajı doldurduğu fotoğraflarla eğitildi; uzaktaki küçük kuşta önce kuşun bulunup kırpılması
gerekir. Bu iş eskiden Apple'ın belirgin nesne isteğiyle (`VNGenerateObjectnessBasedSaliencyImageRequest`)
yapılıyordu: kuşu değil en belirgin nesneyi (insan, tabela, dal) bulabiliyordu. Artık bir nesne algılama modeli
kuşları bulur.

| | |
|---|---|
| Model | YOLOX-S (Megvii), resmi COCO ağırlıkları (sürüm 0.1.1rc0, COCO AP 40,5); yalnızca COCO "bird" sınıfı (14) kullanılır |
| Lisans | **Apache-2.0** (ticari kullanıma engel yok). Lisans metni ve değişiklik notu: `ios/AvHaritasi/BirdPhoto/BirdDetector_LICENSE.txt`; atıf kuş fotoğrafı ekranında. Ultralytics YOLOv5/v8/v11 (AGPL) **kullanılmaz** |
| Boyut | 9,2 MB (int8 doğrusal ağırlık; fp16 18,1 MB) |
| Girdi | `image` 640×640 BGR, 0–255; görüntü en-boy oranı korunarak sol üst köşeye ölçeklenir, kalan alan gri (114) |
| Çıktı | `boxes` [100, 4] (cx, cy, w, h; kare girdiye göre 0–1) ve `scores` [100] (nesne × kuş olasılığı, büyükten küçüğe) |

Çıktının çözümü Swift'te, saf ve birim testli `DetectionDecoder`'dadır (`BirdDetection.swift`): eşik 0,3,
örtüşme bastırma (IoU 0,45), en çok 3 kuş, letterbox → Vision koordinatı dönüşümü ve kırpma bölgesi (kutu
çevresinde pikselde kare, her yana %15 pay, kenarda içeri kaydırılır; kuş kadrajın %60'ından fazlasını
kaplıyorsa kırpılmaz). Model paketten çalışma anında yüklenir (`CoreMLBirdDetector`); yoksa ya da çalışmazsa eski
belirgin nesne kırpmasına düşülür.

Fotoğrafta akış: bulunan her kuş (en çok 3) kırpılıp tür modeline verilir (tek kuşta tam görüntü de); sonucu
tür tahmini en emin olan kuş belirler ve sarı çerçeveyle gösterilir. Kuşların en olası türleri farklıysa ekranda
"Fotoğrafta birden fazla kuş var" bölümü her kuşun ilk tahminini numarasıyla (çerçevedeki numara) ve MAK
durumuyla listeler. Videoda kare puanındaki kuş varlığı, Apple Vision güveni ile bulucunun en iyi kutu puanının
büyüğüdür; seçilen karelerin sınıflandırması da bulucuyla kırpar.

Dönüştürme ve doğrulama (`tools/kus_bulucu`):

```sh
pip install torch torchvision coremltools numpy pillow opencv-python-headless loguru tabulate thop psutil
python tools/kus_bulucu/kus_bulucu.py hepsi   # YOLOX kaynağı (sabit sürüm) + ağırlık (sha256) → Core ML + beklenen kutular
cp -R tools/kus_bulucu/is/BirdDetector.mlpackage ios/AvHaritasi/BirdPhoto/
```

Dönüştürme Linux'ta çalışır; Core ML ile tahmin yalnızca macOS'ta. `kus-bulucu-dogrula.yml` (macOS, model ya da
araç değişince kendiliğinden) modeli `tools/kus_bulucu/ornekler/` altındaki 6 CC0 iNaturalist fotoğrafında
çalıştırır (dosya adındaki sayı gözlem numarasıdır): her birinde kuş bulunmalı, en iyi kutu PyTorch'unkiyle
örtüşmeli (IoU ≥ 0,7, puan farkı ≤ 0,1) ve düz gri görüntüde kuş bulunmamalı.

Gizlilik: bulucu tamamen cihazda çalışır, hiçbir veri göndermez; gizlilik metinleri değişmez.

## Video

Kuş fotoğrafı ekranında galeriden video seçilebilir ya da 10 sn video çekilebilir; video **yalnızca cihazda**
analiz edilir, çevrimiçi kontrole gönderilmez.

1. 10 sn'den uzun videoda ilk 5 dk saniyede bir kare taranır: kare puanı = kuş varlığı (`VNClassifyImageRequest`
   ya da kuş bulucu, hangisi yüksekse) × keskinlik (gri görüntüde Laplace varyansı). Puan toplamı en yüksek 10 sn'lik bölüm seçilir
   (`VideoWindowSelector`); kullanıcı zaman çizelgesinden bölümü kaydırabilir.
2. Bölümden 2 kare/sn örneklenir, en iyi 6 kare tür modeline (kırpma dahil) verilir; sonuçlar kare puanıyla
   ağırlıklı ortalanır (`FrameAggregator`).
3. Bölümün sesi (48 kHz mono) cihazdaki BirdNET'e verilir. İki yol aynı türü gösterirse güven birleştirilir
   (1 − (1 − p_görüntü)(1 − p_ses)); farklıysa "Görüntü" ve "Ses" ayrı gösterilir (`VideoFusion`).

## Mevsim ön bilgisi

Tür olasılıkları o haftaki İstanbul görülme durumuyla yumuşakça ağırlıklandırılır (`SeasonalPrior`):
p' ∝ p · (0,3 + 0,7 · görülme), görülme = `BirdNET_Istanbul_Weeks.json` hafta işaretlerinin ±2 haftalık
ortalaması. Mevsim dışı tür düşer ama silinmez. Ses yolunda BirdNET haftayı kendisi uyguladığından tekrar uygulanmaz.

## Lisans ve künye

Eğitim fotoğraflarının bir kısmı CC BY-NC olduğundan model yalnızca ticari olmayan kullanım içindir.
Fotoğraf sahipleri ve lisansları: `docs/kus_foto/kunye.csv.gz` (sınıf, fotoğraf, sahip, lisans, gözlem bağlantısı).
