# AI_DEVELOPMENT_GUIDE.txt — değerlendirme (Ekim 2026)

Kapsam: yalnızca İstanbul. Yeni bölge ekleme özelliği **yapılmayacak**.
Her öneri gerçek kodla karşılaştırıldı.

## Karar tablosu

| # | Öneri | Karar | Gerekçe |
|---|---|---|---|
| 1 | Tam servis ayrımı (6 servis, AppModel koordinatör) | **Kısmen** | Gerçek cihazda test edilmemiş bir uygulamada büyük yeniden yazım risklidir. Bunun yerine saf karar mantığı ayrılıp test edilir: `AlertPolicy` (bildirim kuralları), `PowerModePolicy` (GPS kademeleri), bayat konum eşikleri. Yan etkiler AppModel'de kalır. |
| 2 | AssessmentCache (50 m / 30 sn) | **Hayır, güvenlik riski** | Yasak alan sınırına doğru yürürken değerlendirme 49 m boyunca eski "avlanabilir" kalır. Mesafe kuralları 300 m / 500 m ve sınırlar onlarca metre hassasiyet ister. Ayrıca gerek yok: aşağıdaki ölçüme bakın. |
| 3 | RetryPolicy (üstel bekleme) | **Yalnızca hava durumu için** | Uygulama başka ağ çağrısı yapmaz: kuş tanıma ve harita çevrimdışı, BirdNET sunucusu kaldırıldı. Hava durumu: 1-2-4-8… dk, en çok 30 dk, ±%10. Çevrimdışıyken hiç denenmez. Harita indirmesi zaten kaldığı yerden devam ediyor. |
| 4 | Ayrıntılı loglama | **Evet, saha kaydı olarak** | Cihazda kalan, 7 günde silinen, yalnızca kullanıcı paylaşırsa dışarı çıkan bir olay günlüğü. Mevcut os.Logger ve MetricKit tanı raporları korunur. |
| 5 | PermitManager / kota | **Gerek yok** | İzin belgesi ayrıştırma, kota ve avlak eşleştirme `HuntPermit` / `PermitStore` / `HarvestLog` içinde zaten var. |
| 6 | LiveActivity seviyeye göre 10/30/60 sn güncelleme | **Hayır** | Live Activity güncellemeleri bütçelidir. Durum değiştiğinde güncellemek doğru davranış; zamanlı güncelleme pil ve bütçe harcar. |
| P1 | Quadtree bölge araması | **Hayır** | Bölge araması poligon taraması değil: ızgarada tek piksel okuma, O(1). "3000+ bölge, 150 ms" bu koda uymuyor. `nearest` sınırlı bir piksel penceresini tarar ve süresi birim testte ölçülür. |
| P2 | Konum işlemeyi arka plana alma | **Ölçüme bağlı** | Değerlendirme süresi birim test kıyaslamasıyla ölçülür. Simülatörde 8 ms'yi geçerse ana iş parçacığından alınır. GPS en çok saniyede 1 güncelleme verir ("50 konum/sn" gerçekçi değil). |
| P3 | SwiftUI ZoneShapeView / throttle | **Uygulanamaz** | Harita MKMapView ile çiziliyor; bölgeler tek bir MKMultiPolygon vektör katmanı. Önerilen SwiftUI kodu bu mimariye uymuyor. |
| P4 | Bellek ([weak self], timer) | **Zaten uygun** | Zamanlayıcılar `[weak self]` kullanıyor. Bellek ölçümü cihaz testinde Instruments ile yapılır. |
| T | Test planı | **Evet, en değerli adım** | Henüz hiç birim testi yok. Eklenecek: `AvHaritasiTests` hedefi, değerlendirme (gerçek harita verisiyle), izin belgesi ayrıştırıcı, benzer tür uyarısı, yer arama, karo paketi, politika testleri ve CI'da `xcodebuild test`. |

## Uygulama (paralel)

- `claude/unit-tests`: test hedefi, testler, kıyaslamalar, CI, `docs/TEST_PLANI.md`
- `claude/policies-refactor`: `AlertPolicy`, `PowerModePolicy`, hava durumu üstel beklemesi ve bunların testleri
- `claude/field-log`: saha kaydı (`FieldLog`), Ayarlar'dan paylaşma ve silme, gizlilik belgeleri

Birleştirme sonrası tüm değişiklikler bağımsız bir kod incelemesinden geçer.
