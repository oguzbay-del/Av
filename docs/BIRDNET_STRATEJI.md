# Kuş sesi tanıma (BirdNET) stratejisi

**Durum (Ekim 2026):** B seçeneği (cihazda BirdNET) uygulandı; model dosyası depoda değil.

- Uygulama 15 sn kayıt alıyor (48 kHz mono WAV).
- Sıra (`BirdIDModel.plannedPath`):
  1. `BirdNET.mlmodelc` pakette varsa **cihazda BirdNET** (`ios/AvHaritasi/BirdNET/BirdNETOnDevice.swift`). Ses ve konum telefondan çıkmaz.
  2. Ayarlar'da sunucu adresi varsa ve cihazdaki model yoksa (ya da "Cihazdaki model yerine sunucuyu kullan" açıksa) `server/birdnet-api` sunucusu. Sunucuya ulaşılamazsa cihazdaki modele düşer.
  3. İkisi de yoksa/sonuç çıkmazsa Apple SoundAnalysis (yalnızca grup).
- Kuş ekranının açıklaması etkin yola göre değişir (cihazda: "ses ve konum telefondan çıkmaz").

## Modeli uygulamaya eklemek

1. GitHub Actions › **BirdNET Core ML** iş akışını çalıştırın (ya da yerelde `python3 tools/birdnet_coreml.py --out build/birdnet`; Core ML doğrulaması yalnızca macOS'ta).
2. Yapıttaki `BirdNET.mlpackage` klasörünü `ios/AvHaritasi/BirdNET/` içine koyun. Klasör Xcode'da eşitlenmiş grup olduğu için başka bir şey gerekmez; Xcode modeli `BirdNET.mlmodelc` olarak derleyip pakete ekler ve uygulama onu çalışma anında yükler.
3. `BirdNET_Istanbul_Weeks.json`, `BirdNET_LICENSE.txt` ve `BirdNET_ATTRIBUTION.md` zaten depoda, aynı klasörde.

Model (~26 MB) bilerek commit edilmiyor (`.gitignore`): depo her klonda 26 MB büyür, model her çevirmede baytça değişebilir ve NC-SA lisanslı ikili dosyanın dağıtımı geliştiricinin kararı olmalı. Sürüm (TestFlight) derlemesinde modelin olması isteniyorsa `.gitignore` satırı kaldırılıp model commit edilebilir ya da TestFlight iş akışına yapıtı indirme adımı eklenebilir.

### Çeviri (tools/birdnet_coreml.py)

- **Kaynak:** Zenodo kaydı 15050749 ("BirdNET Model V2.4"; BirdNET-Analyzer ve `birdnet` pip paketi de buradan indirir). `BirdNET_v2.4_keras.zip` (audio-model.h5) çevrilir; `BirdNET_v2.4_tflite.zip` içindeki `audio-model.tflite` referanstır (birdnetlib'deki `BirdNET_GLOBAL_6K_V2.4_Model_FP32.tflite` ile aynı md5), `meta-model.tflite` hafta listesini üretir. İki zip md5 ile doğrulanır; indirilen Python kodu çalıştırılmaz.
- **Spektrogram modelin içinde.** BirdNET'in `MelSpecLayerSimple` katmanı STFT'nin karmaşık sonucunu `tf.cast` ile float'a çevirir; bu yalnızca gerçel kısmı alır. Gerçel kısım (Hann × kosinüs) ve mel matrisi doğrusal olduğu için tek bir Conv1D çekirdeğine katlanır (2 048 × 96, adım 278; 1 024 × 96, adım 280); mel ekseninin ters çevrilmesi de çekirdek sırasına katlanır. Böylece Swift'te vDSP ile spektrogram yazmaya gerek kalmadı. (x²)^a yerine |x|^(2a) kullanılır (FP16'da x² taşar).
- **Çıktı logit:** Son sigmoid çıkarıldı (referans TFLite gibi); üst veride `birdnet.output = logits`. Uygulama sigmoid uygular.
- **Doğrulama:** Keras eşdeğeri (FP32) referans TFLite ile depodaki 4 kuş sesi, 2 tam Xeno-canto kaydı ve gürültüde ilk-5 tahminde birebir aynı (en büyük olasılık farkı 0,0001). macOS iş akışı Core ML modelini de (CPU ve ALL) karşılaştırır; CPU'da her pencerede ilk-5 kümesi aynı değilse iş başarısız olur.
- **Boyut:** FP16 mlpackage ~26 MB.

### Yer/mevsim süzgeci

`ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json` (~49 KB, depoda): BirdNET meta modeli ile 41,1 K / 29,0 D, hafta 1–48, eşik 0,03 → 319 tür (hafta başına 217–288). MAK EK-1/EK-2'deki türler bölgede olası görünmese de listede (haftaları "000…" olabilir): bunlar gösterilmez ama "benzer korunan tür" karşılaştırmasına girer. MAK'taki `Spilopelia senegalensis` BirdNET'te `Streptopelia senegalensis`; JSON'da `mak` alanıyla eşlenir. BirdNET'te olmayan MAK türleri: Ammoperdix griseogularis, Bucanetes mongolicus, Ichthyaetus ichthyaetus, Larus armenicus, Oenanthe lugens, Rhodopechys sanguineus.

### Uygulamadaki akış

- Kayıt `AVAudioFile` ile okunur, 48 kHz mono değilse `AVAudioConverter` ile çevrilir; 3 sn pencere, 1,5 sn adım (15 sn → 9 pencere).
- Tür başına en yüksek olasılık; gösterim: o haftanın listesinde ve ≥ 0,5; ≥ 0,7 "yüksek güven" (yeşil).
- **Güvenlik kuralı:** gösterilen bir av türüne skoru 0,15'ten yakın (ya da daha yüksek) koruma altında bir tür varsa (aday eşiği 0,35, bölge dışı MAK türleri dahil) satırda kırmızı "Emin değil — benzer korunan tür: X" yazar. Kural sunucu sonuçlarına da uygulanır.

### Cihazda denenmesi gerekenler

- Gerçek iPhone'da Neural Engine/GPU (FP16) sonuçlarının CPU ile aynı olduğu; süre (hedef < 1 sn / 15 sn kayıt) ve bellek.
- AVAudioRecorder'ın gerçekten 48 kHz kaydettiği (farklıysa dönüştürme yolu).
- Strateji adım 4'teki Xeno-canto doğruluk tablosu (av türü ilk-1 ≥ %80, korunanın av türü sanılması ≤ %5) henüz çıkarılmadı.

## Kısıtlar

| Kısıt | Neden önemli |
|---|---|
| Arazide şebeke yok/zayıf | Orman ve sulak alanların çoğunda veri bağlantısı yok. Sunucuya bağlı bir özellik en çok gerektiği yerde çalışmaz. |
| Lisans: BirdNET modeli **CC BY-NC-SA 4.0** | Yalnızca ticari olmayan kullanıma izin verir ve atıf ister. Modelden türetilen dosyalar (ör. CoreML'e çevrilmiş model) da aynı lisansla paylaşılmalıdır. Uygulama ücretli olursa, reklam alırsa ya da uygulama içi satın alma içerirse Cornell K. Lisa Yang Center'dan ticari lisans gerekir. |
| Gizlilik / KVKK | Ses kaydı ve konum sunucuya gidiyor. Sunucu, gizlilik politikasında ayrı bir alıcı olarak yazılmalı ve bir işletmecisi olmalı. |
| App Review | Kullanıcının elle sunucu adresi girmesi gereken bir özellik inceleme ekibine "çalışmıyor" görünür (Guideline 2.1). |
| Güvenlik | Tahmin, ateş etme kararı için kullanılmamalı. Koruma altındaki türler av türlerine benzer ses çıkarabilir. |

## Seçenekler

| | A. Barındırılan API | B. Cihazda model (önerilen) | C. Karma |
|---|---|---|---|
| Nasıl | `server/birdnet-api`: HF Spaces (ücretsiz CPU) ya da Google Cloud Run | BirdNET V2.4'ü CoreML'e çevirip uygulamaya gömmek (FP16, ~25 MB) | Kayıt cihazda sınıflandırılır; internet varsa sunucuya ikinci görüş için gönderilebilir |
| Şebekesiz çalışır | Hayır | **Evet** | Evet |
| Gecikme | 1–3 sn; uyku sonrası soğuk başlangıç 20–60 sn | ~0,3–1 sn (Neural Engine) | ~1 sn |
| Maliyet | HF ücretsiz (48 saat sonra uyur); Cloud Run ölçeğe göre ~0–10 $/ay | 0 | Düşük |
| Gizlilik | Ses + yaklaşık konum dışarı çıkar | **Hiçbir şey çıkmaz** | Yalnızca kullanıcı isterse dışarı çıkar |
| Uygulama boyutu | +0 | +25 MB (FP16) / +13 MB (8 bit nicemleme; doğruluk kontrol edilmeli) | +25 MB |
| Bakım | Sunucu, kimlik doğrulama, kötüye kullanım | Model güncellemesi uygulama sürümüyle gelir | İkisi birden |

## Öneri: B. Cihazda BirdNET

### Adımlar

1. **Model çevirme**
   - `tools/birdnet_coreml.py` yazılacak.
   - Girdi: BirdNET-Analyzer V2.4 TFLite/SavedModel.
   - `coremltools` ile şu model elde edilecek:
     - girdi: 48 kHz mono, 3 sn (144 000 örnek); spektrogram modelin içinde,
     - çıktı: 6 522 sınıf.
   - Bu model `BirdNET_V24.mlpackage` (FP16) olarak kaydedilecek.
   - Lisans dosyası ve atıf modelin yanına konacak (NC-SA).
2. **Yer/mevsim süzgeci**
   - BirdNET'in "meta" modeli (enlem, boylam, hafta → olası türler) de çevrilecek, ya da İstanbul için 48 haftalık bir tür listesi bir kez üretilip JSON olarak gömülecek (daha basit, ~30 KB).
   - Bu süzgeç yanlış tahminleri belirgin biçimde azaltır.
3. **Swift tarafı**
   - `BirdNETOnDevice` sınıfı (`DeviceSoundClassifier`'ın yerine geçer):
     - kayıt 3 sn'lik, 1,5 sn örtüşen pencerelere bölünür,
     - pencereler sınıflandırılır, sonra sigmoid uygulanır,
     - tür başına en yüksek skor alınır,
     - süzgeçten geçen türler gösterilir: eşik ≥ 0,5, "yüksek güven" ≥ 0,7.
   - Mevcut `DetectionRow` ve MAK yasal durum gösterimi aynen kullanılır.
4. **Doğrulama**
   - `tools/fetch_sounds.py` ile Xeno-canto'dan Türkiye kayıtları indirilecek: av türleri ve onlarla karıştırılabilecek korunan türler (ör. üveyik ↔ kumru, bıldırcın ↔ çayır kuşu), tür başına 20 kayıt.
   - Tür bazında isabet ve karışıklık tablosu çıkarılacak.
   - Kabul ölçütü: av türlerinde en iyi 1 tahmin doğruluğu ≥ %80.
   - Korunan bir türün av türü olarak gösterilme oranı ≤ %5 olmalı. Aşılırsa o çift için "Benzer korunan tür var" uyarısı gösterilecek.
5. **Arayüz ve güvenlik**
   - Tahmin listesinin üstünde sabit bir uyarı olacak.
   - Av türü ile korunan tür arasında 0,15'ten küçük skor farkı varsa tahmin kırmızıyla "Emin değil" olarak işaretlenecek.
6. **Sunucu yolu isteğe bağlı kalır**
   - Ayarlar'daki sunucu adresi gelişmiş kullanıcılar için kalır.
   - Varsayılan boş; App Review notlarına gerek yok.

### Lisans kararı (geliştiricinin vereceği)

- Not: Zenodo kaydı (15050749) lisansı "CC BY-NC 4.0" gösteriyor; BirdNET-Analyzer deposu ve birdnetlib modelleri CC BY-NC-SA 4.0 ile dağıtıyor. Daha kısıtlayıcı olan **CC BY-NC-SA 4.0** esas alındı (lisans metni `ios/AvHaritasi/BirdNET/BirdNET_LICENSE.txt`, atıf `BirdNET_ATTRIBUTION.md`).

- Uygulama **ücretsiz, reklamsız ve satın almasız** kalacaksa NC-SA koşulları sağlanır. Gereken atıf zaten var: Ayarlar ve kuş ekranının altında. Ayrıca model dosyasının lisans metni uygulamaya eklenecek.
- Gelir modeli düşünülüyorsa iki seçenek var:
  - Cornell'den (ccb-birdnet@cornell.edu) ticari lisans istemek,
  - kuş tanıma özelliğini kapatmak.

### Tahmini iş

| İş | Süre |
|---|---|
| Model çevirme ve boyut/doğruluk karşılaştırması | 1 gün |
| Swift entegrasyonu | 1 gün |
| Xeno-canto doğrulaması | 1 gün |
| Arayüz uyarıları | 0,5 gün |

CI'da `xcodebuild` model derlemesi (mlpackage → mlmodelc) otomatik yapılır.

### Riskler

- TFLite → CoreML çevirisinde özel katmanlar (spektrogram) desteklenmeyebilir. Bu durumda spektrogram Swift'te (vDSP) hesaplanır ve yalnızca CNN kısmı çevrilir.
- BirdNET sürüm değişikliklerinde sınıf listesi kayar. Etiketler model sürümüyle birlikte sabitlenir.
