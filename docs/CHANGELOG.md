# Değişiklik günlüğü

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) temel alınmıştır; sürümler
[Anlamsal Sürümleme](https://semver.org/lang/tr/) izler. Yeni sürüm için başlık ekleyin, ardından
`fastlane/metadata/*/release_notes.txt` dosyalarını güncelleyip `vX.Y.Z` etiketi gönderin (bkz. `docs/YAYIN.md`).

## [Yayımlanmadı]

### Eklendi
- TestFlight otomasyonu: fastlane `beta` lane'i, `.github/workflows/testflight.yml`, paylaşılan Xcode şeması.
- SwiftLint yapılandırması ve bilgilendirme amaçlı lint iş akışı.

## [1.0.0] — ilk sürüm

### Eklendi
- **Harita:** İstanbul Avlaklar Haritası 2026-2027'den vektöre çevrilmiş bölgeler (ava yasak, özel kanunla
  korunan, YHYS, devlet avlağı, genel avlak, örnek avlak); isteğe bağlı taranmış resmi harita katmanı.
- Altlıklar: Apple Uydu / Standart, OpenTopoMap ve OpenStreetMap (gezilen karolar çevrimdışı önbellekte).
- **Durum şeridi:** 2026-2027 MAK kararına göre yer + zaman + tür değerlendirmesi — Avlanmayın / Dikkat /
  Avlanabilirsiniz; dokununca tüm kural kontrolleri.
- 300 m / 500 m mesafe yasakları, isteğe bağlı 300 m bantları, en yakın yasak alan göstergesi ve yönü.
- Yer arama (çevrimdışı köy/ilçe/mesire + Apple Haritalar), uzun basarak nokta değerlendirmesi, 3B arazi.
- Rüzgâr rozeti ve koku konisi; pusula ile yasak alan okunun telefon yönüne göre dönmesi.
- **Uygulama kapalıyken uyarı:** CLMonitor ile yasak alana ~100 m kala bildirim; hareketsizken pil tasarrufu.
- **Avlanma İzin Belgesi:** ekran görüntüsü/fotoğraf/PDF'ten cihazda okuma (Vision OCR, PDFKit), avlağın
  vurgulanması ve yol tarifi; kişisel bilgiler saklanmaz.
- **Bugün:** av günü, konuma göre av saati, açık türler ve günlük limitler, sonraki av günleri, sezon
  tarihleri; Open-Meteo hava ve rüzgâr tahmini; Tablo-4 limitlerine uyan av defteri sayacı.
- **Kuş Sesi:** BirdNET (kendi sunucunuzda) ile tür tahmini ve MAK EK-1/EK-2 eşlemesi; çevrimdışı yedek
  olarak cihazdaki ses sınıflandırıcı.
- **Kilit ekranı / Dynamic Island / Apple Watch:** Live Activity ile canlı av durumu ve rüzgâr.
- **Kurallar:** İstanbul 2026-27 değişiklikleri, mesafe yasakları, avlaklar, korunan alanlar, önemli
  yasaklar; madde numaralarıyla.
- iOS 26 Liquid Glass tasarımı (iOS 17–25'te buzlu cam), özel av simgeleri, aydınlık/koyu/renkli ikon.
- Türkçe ve İngilizce arayüz; gerçek kuş sesleriyle açılış ve uyarı sesleri.
