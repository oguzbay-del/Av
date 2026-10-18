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

## Video

Kuş fotoğrafı ekranında galeriden video seçilebilir ya da 10 sn video çekilebilir; video **yalnızca cihazda**
analiz edilir, çevrimiçi kontrole gönderilmez.

1. 10 sn'den uzun videoda ilk 5 dk saniyede bir kare taranır: kare puanı = kuş varlığı (`VNClassifyImageRequest`)
   × keskinlik (gri görüntüde Laplace varyansı). Puan toplamı en yüksek 10 sn'lik bölüm seçilir
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
