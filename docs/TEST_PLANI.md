# Test planı

Av Haritası'nın otomatik birim testleri ve saha testleriyle ilişkisi.

## Birim testleri (`ios/AvHaritasiTests/`)

`AvHaritasiTests` bir XCTest paketidir; **uygulamanın içinde** koşar (`TEST_HOST` = AvHaritasi.app,
`@testable import AvHaritasi`). Böylece testler uygulamayla gelen gerçek veriyi kullanır:
`istanbul_2026_2027` haritası, `istanbul_2024_2025` öğeleri (köy/yol/avlak birimi), `mak_2026_2027.json`,
OSM katmanı ve `istanbul_topo_low.avtp`.

Klasör Xcode'da **eşitlenmiş klasör** (`PBXFileSystemSynchronizedRootGroup`) olarak tanımlıdır:
`ios/AvHaritasiTests/` içine bırakılan her `.swift` dosyası projeye dokunmadan derlenir.

| Dosya | Kapsam |
|---|---|
| `AssessmentTests.swift` | Bilinen noktalar: Sarıkavak tarafı devlet avlağı başlangıcı `41.02446, 29.65804` → güvenli; Ava Yasak Alan içi `41.01971, 29.64790` → tehlike; Şile `41.10, 29.53` → güvenli; Dereli köyüne ~90 m → tehlike (Madde 8/7); harita dışı → bilinmiyor. GPS doğruluğu düşükken "dikkat"; doğruluk yasak alan uyarı tamponunu genişletir. `Assessment.reducedAccuracy` (Kesin Konum kapalı) ve `Assessment.stale` (bayat konum asla "dikkat"in altında değil). |
| `AssessmentTests.swift` › `TimeRuleTests` | Çarşamba av günü / Perşembe değil; Perşembe'de genel seviye tehlike ama `placeLevel` güvenli kalır (bildirimler mekâna göre); zaman kuralları kapatılabilir; 29 Ekim resmi tatil; Salı yalnız ek gruplar; av saati penceresi (gün doğumu −1 sa, batımı +1 sa); sezon dışı; sonraki av günleri. |
| `PermitParserTests.swift` | AVBİS izin belgesinin OCR metni (yapay örnek: Beykoz D.A., 4.10.2026, belge no 42793703, Bıldırcın 10, Üveyik 3): satır ve sütun düzeni, eksik kota → MAK limiti, OCR boşluk/harf hataları, bilinmeyen avlak, yanlış sezon, konumlu OCR'da **dipnottaki "izin verilen" ifadesinin tablo başlığı sanılmaması**, belgenin yalnız kendi gününde (İstanbul saatiyle) geçerli olması. |
| `BirdTests.swift` | `BirdLookalike.mark` (korunan türle skor farkı < 0,15 → "emin değil"), `BirdNETWeek.week(for:)` (48 haftalık yıl, İstanbul günü), `BirdLabel.parse` (model etiket biçimleri). |
| `PlaceIndexTests.swift` | Türkçeye duyarsız arama: "sile" → Şile, "agva" → Ağva, OCR'ın böldüğü "Gaz İtepe" ↔ "gazitepe"; sıralama ve sınırlar. |
| `TilePackTests.swift` | AVTP başlığı ve dizini, bilinen z8 karosunun (148/96) 256×256 görüntü olarak çözülmesi, bozuk dosyanın reddi, `TileImage.upscale` çıktı boyutu, boş/deniz karoları. `GeofenceRadiusTests`: güvenli daire yarıçapı 200–3000 m aralığına sıkıştırılır, yasak alana ~100 m kala uyanır. |
| `PerformanceTests.swift` | 20 noktada `Assessment.evaluate` ve `HuntingMap.nearest(within: 3000)` süreleri (XCTest `measure` + günlükte `BENCH` satırları). |

Başka bir çalışmada eklenecek `AlertPolicyTests.swift` / `PowerModePolicyTests.swift` de bu klasöre girer.

### Başarım eşiği

`Assessment.evaluate` her konum güncellemesinde ana iş parçacığında çalışır. CI simülatöründe
değerlendirme başına **> 8 ms** ölçülürse değerlendirme ana iş parçacığından alınmalıdır.
Ölçümler Debug (`-Onone`) derlemesindedir; App Store sürümü (Release, `-O`) daha hızlıdır, yani
Debug'da eşiğin altında kalan sonuç Release için de geçerlidir. Sonuçlar CI iş özetinde
("Başarım ölçümleri") ve `derleme-kayitlari` içindeki `test.log`'da `BENCH` satırlarıdır.

İlk ölçüm (CI, iPhone 16 / iOS 26.2 simülatörü, Debug, 2026-10-09):

| Ölçüm | Ortalama | En kötü nokta |
|---|---|---|
| `Assessment.evaluate` (nokta başına) | 1,6–1,9 ms | 3,4–3,7 ms (Dereli köyü yakını) |
| `HuntingMap.nearest(within: 3000)` (nokta başına) | 9,1–10,8 ms | 11,0–12,4 ms |

`evaluate` eşiğin çok altında. Ancak `AppModel.reassess` her konum güncellemesinde `evaluate`'ten
sonra `nearest(within: 3000)` da çağırır (yasak alan içinde değilken); ikisi birlikte Debug'da
~11–14 ms eder. Taşınacak bir şey varsa önce bu 3 km taramasıdır.

### Test için yapılan küçük değişiklik

- `Geofence.radius(distanceToForbidden:)`: güvenli daire yarıçapı hesabı `arm(at:)` içinden ayrı,
  `nonisolated` bir fonksiyona alındı (davranış aynı); CLMonitor olmadan test edilebilsin diye.

Zaman kuralları için ek bir kanca gerekmedi: `Assessment.evaluate(at:)` ve `Regulations` tarih alır.

## Çalıştırma

Xcode: **Product › Test** (⌘U), `AvHaritasi` şeması.

Komut satırı:

```sh
xcodebuild test -project ios/AvHaritasi.xcodeproj -scheme AvHaritasi \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ios/build/DerivedData -testLanguage tr -testRegion TR
# tek bir sınıf:
#   ... -only-testing:AvHaritasiTests/PermitParserTests
```

CI: `.github/workflows/ios-build.yml` › "Birim testleri (iPhone simülatörü)". Simülatör, en yeni
iOS çalışma zamanındaki iPhone'dan dinamik seçilir (`tools/screenshots.sh` ile aynı yöntem). Test
başarısız olursa `.xcresult` paketi `test-sonuclari-xcresult` adıyla yüklenir.

## Kapsam dışı (elle / sahada)

Birim testleri kural motorunu ve veri okumayı doğrular; konum servisinin, arka plan uyandırmasının,
bildirimlerin ve pilin gerçek davranışını doğrulamaz. Bunlar için:

- **Simülatör senaryoları:** `ios/TestData/GPX/README.md` (yasak alana giriş, sınır boyunca, köy yakını,
  korunan alan tamponu, GPS kesintisi, hareketsiz pusu; beklenen bant/bildirim zamanlarıyla).
- **Saha testi:** [`docs/saha_test_protokolu.md`](saha_test_protokolu.md) — aynı alanlarda (A–E) gerçek
  cihazla T1–T14 vakaları, ölçülecek uyarı mesafesi/gecikme ve kabul ölçütleri.
