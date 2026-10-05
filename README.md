# Av Haritası (iOS)

Konumunuzu Tarım ve Orman Bakanlığı'nın avlak haritası üzerinde gösteren bir iPhone uygulaması. Bulunduğunuz yeri
ve anı **2026-2027 Merkez Av Komisyonu (MAK) kararına** göre değerlendirir: yer, zaman ve tür.
Yasak bir alana girdiğinizde ya da yaklaştığınızda sizi uyarır.

- Alan haritası: **34 İstanbul Avlaklar Haritası 2026-2027**. Bu dosya taranmış bir görüntü
  (`maps/34_istanbul_2026_2027_orijinal.pdf`); koordinatları, aynı şablonla basılmış 2024-2025 GeoPDF'ine
  (`maps/34_istanbul_2024_2025.pdf`) hizalanarak bulundu.
- Kurallar: **2026-2027 Av Dönemi MAK Kararı**, Resmî Gazete 07.06.2026 (`maps/mak_2026_2027.pdf`)

![Sınıflandırma önizlemesi](docs/siniflandirma_onizleme.png)

## Ne yapar?

**Harita sekmesi**
- Altlık seçilebilir: Apple Uydu+yol / Uydu / Standart, **OpenTopoMap** (eş yükselti eğrileri, patikalar) ve
  **OpenStreetMap**. OSM ve Topo karoları gezdikçe cihaza kaydedilir; ormanda internet olmadan da görünür.
- Üstünde resmi 2026-27 avlak haritası (opaklığı ayarlanabilir) gösterilir. Haritada küçük kalan veya
  görünmeyen ama kararda geçen alanlar (Adalar, Kızılcaköy-Soğullu YHYS) kesikli çizgiyle eklenir.
- İsteğe bağlı **300 m yasak bantları**: karayolları, köy ve ilçe merkezleri, mesire yerleri.
- Üstteki durum şeridi:
  - 🟥 **Avlanmayın:** yasak alan, korunan alanın 300 m yakını, köy, mesire yeri veya karayoluna 300 m'den
    yakın, kapalı avlak, av günü değil, av saati dışı.
  - 🟧 **Dikkat:** sınıra yakın, örnek avlak, yeri belirsiz yasak alan, asfalt yol, köyün dış evleri olabilir,
    GPS doğruluğu düşük.
  - 🟩 **Avlanabilirsiniz:** devlet veya genel avlak, mesafe kurallarına uygun, bugün av günü ve av saati içinde.

  Şeride dokununca tüm kural kontrolleri tek tek listelenir.
- Haritaya **uzun basınca** o noktanın mekânsal değerlendirmesi görünür (gitmeden önce plan yapmak için).
- Titreşim, ses ve **arka plan bildirimi** var. Bildirimler yalnızca yer kurallarına göre gelir; örneğin
  Pazartesi günü "av günü değil" bildirimi gelmez.

**Bugün sekmesi:** Seçilen günün av günü olup olmadığı, konuma göre avlanma saati (gün doğumundan 1 saat önce –
gün batımından 1 saat sonra), o gün açık türler ve günlük limitleri, sonraki av günleri, Marmara sezon tarihleri,
limit tablosu.

**Kurallar sekmesi:** İstanbul için 2026-27 değişiklikleri, mesafe yasakları, avlaklar (açık/kapalı ve içindeki
avlak dışı alanlar), korunan alan listeleri, önemli yasaklar (tüfek, gece görüş, araç, sürek avı…). Her
kuralın yanında madde numarası var.

## Neden bu teknoloji?

| Seçenek | Karar | Gerekçe |
|---|---|---|
| **SwiftUI + MapKit** | ✅ Kullanıldı | Ek bağımlılık ve API anahtarı yok, ücretsiz. Arka planda konum ve bildirim en güvenilir şekilde native çalışıyor. Özel karo katmanı ve çokgen çizimi destekleniyor. |
| OpenStreetMap / OpenTopoMap | ✅ Altlık olarak | Arazi için en faydalı altlık (patika, eş yükselti). MapKit üzerine karo katmanı olarak eklendi. Görüntülenen karolar önbelleğe alınıyor; toplu indirme yapılmıyor (OSM kullanım politikası). |
| Apple Uydu | ✅ Altlık olarak | Orman ve tarla sınırlarını görmek için. |
| Google Maps SDK | ❌ | API anahtarı ve faturalandırma gerektiriyor. Karoların çevrimdışı saklanmasına lisans izin vermiyor. |
| Mapbox / MapLibre Native | Sonra | Vektör tabanlı çevrimdışı haritalar için en iyi seçenek, ama stil ve karo barındırma gerektiriyor. Tam çevrimdışı bölge paketi gerekirse geçiş yolu bu. |
| Flutter / React Native | Sonra | Android sürümü istenirse düşünülebilir (Flutter + flutter_map + OSM). Bugün iOS'ta native en sağlam yol. |

## Veri hattı

```
maps/34_istanbul_2026_2027_orijinal.pdf  (taranmış JPEG, koordinatsız)
  └─ tools/georef_scan.py (2024-25 GeoPDF'ine OpenCV ECC ile hizalama, korelasyon 0,998)
       → maps/34_istanbul_2026_2027.pdf (GeoPDF)
       └─ tools/generate_assets.py --scan → istanbul_2026_2027.zones.bin / .tiles / .json
maps/34_istanbul_2024_2025.pdf  (vektörlü GeoPDF, WGS84)
  └─ tools/extract_features.py → *.features.json (köy/ilçe/mesire, karayolu/asfalt), *.units.bin (avlak birimleri)
maps/mak_2026_2027.pdf  (463 sayfa, taranmış)
  ├─ tools/ocr_pdf.py → docs/mak_2026_2027_ocr.txt
  └─ elle yapılandırıldı → ios/AvHaritasi/MapData/mak_2026_2027.json
```

Belgenin nasıl bölümlendiği ve okunduğu `docs/MAK_2026_2027_okuma.md` dosyasında anlatılıyor.

## Kurulum (Mac + Xcode 16+)

1. `ios/AvHaritasi.xcodeproj` dosyasını açın.
2. *AvHaritasi* hedefi → **Signing & Capabilities** → **Team** olarak Apple kimliğinizi seçin. Gerekirse
   Bundle Identifier'ı benzersiz yapın.
3. iPhone'u bağlayın ve ▶︎ ile çalıştırın. İlk seferde *Ayarlar → Genel → VPN ve Aygıt Yönetimi*'nden
   geliştiriciye güvenin ve *Gizlilik ve Güvenlik → Geliştirici Modu*'nu açın.
4. Konum izni: "Uygulamayı Kullanırken". Arka plan uyarısı için Ayarlar'dan *Arka planda takip*'i açın.

Ücretsiz Apple ID ile yüklenen uygulama 7 günde bir yeniden yüklenmelidir.

## Yeni sezon / başka il

```bash
pip install pymupdf numpy scipy pillow scikit-image opencv-python-headless
# Taranmış haritayı koordinatlandır (aynı şablonla basılmış bir GeoPDF referans olarak gerekir)
python3 tools/georef_scan.py maps/34_istanbul_2024_2025.pdf maps/34_istanbul_2026_2027_orijinal.pdf \
    maps/34_istanbul_2026_2027.pdf --check docs/hizalama.png
python3 tools/generate_assets.py maps/34_istanbul_2026_2027.pdf --scan --name istanbul_2026_2027 \
    --title "İstanbul Avlaklar Haritası" --season "2026-2027" --out ios/AvHaritasi/MapData \
    --preview docs/siniflandirma_onizleme.png
# Vektörlü GeoPDF varsa --scan olmadan doğrudan; köy/yol vektörleri için:
python3 tools/extract_features.py maps/34_istanbul_2024_2025.pdf --name istanbul_2024_2025 --out ios/AvHaritasi/MapData
```

Yeni MAK kararında `mak_2026_2027.json` güncellenir: gruplar, tarihler, limitler, değişiklikler, `overrides`.
Güncel resmi harita yayımlandığında yaklaşık çizilmiş `overrides` alanları kaldırılabilir.

## ⚠️ Sınırlamalar

- **Uygulama resmi değildir.** Yasal sorumluluk avcıya aittir.
- 2026-27 haritası taranmış bir görüntü. Alanlar renkten okunuyor ve yazı ile çizgiler süzülüyor; çok küçük
  alanlar (birkaç yüz metre) kaybolabilir. Adalar bu yüzden ayrıca işaretlendi. Kızılcaköy-Soğullu YHYS
  haritada görünmediği için geniş bir "dikkat" alanı olarak eklendi.
- Köy/yol vektörleri ve avlak birim adları 2024-25 haritasından geliyor. 2026-27'de birim adları değişmiş
  olabilir (ör. Kocaeli Ovacık D.A.).
- Harita 1:490.000 ölçekli; sınırlar birkaç yüz metre sapabilir.
- Köy mesafesi köy merkezi noktasından hesaplanıyor. Köyün en dış evleri için kendi gözleminizi esas alın.
- Yol sınıfı haritadan alındı: Karayolu ve Ekspres yol KGM yolu kabul edildi, asfalt yollar "dikkat".
- 500 m kuralındaki askeri alan, okul, sağlık tesisi, cezaevi gibi yerler için veri yok.
- Av günü: resmi tatiller listede var. Sonradan ilan edilecek idari tatilleri kendiniz kontrol edin.
- Yeşil durum; avcılık belgesi, avlanma izin kartı, AVBİS izni ve kota yükümlülüklerini kaldırmaz.

## Dosya yapısı

```
ios/AvHaritasi/
  AvHaritasiApp.swift
  Model/
    HuntingMap.swift       Bölge ızgarası (renk sınıfları), en yakın bölge araması
    MapFeatures.swift      Köy/ilçe/mesire noktaları, yollar, avlak birimleri
    Regulations.swift      MAK kuralları: sezon, gün, saat, tür, limit, değişiklikler
    Assessment.swift       Yer + zaman kural motoru
    Geo.swift, Sun.swift   Geometri, gün doğumu/batımı
    TilePack.swift         Resmi harita karo paketi
    BaseLayers.swift       Apple / OpenTopoMap / OSM altlıkları ve önbellek
    AppModel.swift         Konum, değerlendirme, uyarılar
  Views/                   Harita, Bugün, Kurallar, Ayarlar, Lejant
  MapData/                 Üretilmiş veriler
tools/                     PDF → veri araçları
docs/                      Okuma stratejisi, OCR metni, önizleme
maps/                      Kaynak PDF'ler
```
