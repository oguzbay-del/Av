# Kuş sesi tanıma (BirdNET) stratejisi

**Durum (Ekim 2026):**

- Uygulama 15 sn kayıt alıyor.
- Kullanıcı Ayarlar'da bir sunucu adresi girdiyse kaydı `server/birdnet-api` sunucusuna gönderiyor (FastAPI + birdnetlib). Sunucu henüz hiçbir yerde çalışmıyor.
- Sunucu adresi yoksa iOS'un kendi ses sınıflandırıcısına (SoundAnalysis) düşüyor. Bu sınıflandırıcı türü değil, yalnızca "kuş" sınıfını tanır.
- Varsayılan kurulumda kullanıcı tür tahmini alamıyor.

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
