# Av Haritası (iOS)

Güncel konumunuzu Tarım ve Orman Bakanlığı'nın **avlak haritası** üzerinde gösteren ve
**ava yasak / korunan bir alana girdiğinizde ya da yaklaştığınızda** sizi uyaran iPhone uygulaması.

Şu an içinde **34 İstanbul Avlaklar Haritası (2024-2025)** bulunuyor (`maps/34_istanbul_2024_2025.pdf`).

![Sınıflandırma önizlemesi](docs/siniflandirma_onizleme.png)

## Ne yapar?

- Apple haritası (uydu/standart) üzerine resmi avlak haritasını katman olarak çizer, konumunuzu gösterir.
- Ekranın üstünde anlık durum:
  - 🟥 **Kırmızı** – Ava Yasak Alan, Özel Kanunlarla Korunan Alan veya Yaban Hayvanı Yerleştirme Sahası içindesiniz.
  - 🟧 **Turuncu** – Yasak alana ayarladığınız mesafeden (varsayılan 300 m) + GPS hata payından daha yakınsınız;
    ya da Örnek Avlak / işaretsiz alan / GPS doğruluğu düşük.
  - 🟩 **Yeşil** – Devlet Avlağı veya Genel Avlak; yakında yasak alan yok.
- Duruma geçişte titreşim + ses; **arka planda takip** açıksa telefon cebinizdeyken bildirim gönderir
  (yasak alanda kaldıkça 2 dakikada bir tekrarlar).
- Haritaya **uzun basarak** herhangi bir noktanın hangi alanda olduğunu sorgulayabilirsiniz (gitmeden önce plan için).
- İnternetsiz çalışır: avlak haritası ve bölge verisi uygulamanın içindedir (Apple altlık haritası için internet gerekir,
  ama uyarılar internetsiz de çalışır).
- Konum hiçbir yere gönderilmez.

## Nasıl çalışır?

Bakanlığın PDF haritası bir **GeoPDF**'tir: köşe koordinatları (WGS84) dosyanın içinde kayıtlıdır, harita
WGS84 enlem/boylam (eşdikdörtgen) projeksiyonundadır. `tools/generate_assets.py`:

1. Gömülü koordinat referansını okur (elle hizalama yok).
2. Yazıları, yolları ve sınır çizgilerini silip yalnızca renkli alan katmanını işler ve her pikseli lejant
   rengine göre sınıflandırır (~26 m × 34 m hücreler) → `*.zones.bin`.
3. Haritayı Web Mercator karolarına böler (z8–z13, tek dosya) → `*.tiles`.
4. Meta veriyi yazar → `*.json`.

Uygulama konumunuzu aynı dönüşümle ızgaradaki hücreye çevirip sınıfı okur, çevredeki yasak hücrelere
olan en kısa mesafeyi hesaplar.

Doğrulama: Sarayburnu, Rumeli Feneri, Şile Feneri, Karaburun, Yeşilköy ve Tuzla burnu koordinatları
haritadaki kıyı çizgisine oturuyor; Belgrad Ormanı → Korunan Alan, Çatalca → Devlet Avlağı,
Silivri batısı → Genel Avlak, Gebze D.A. yasak bölgesi → Ava Yasak Alan.

## Kurulum (Mac + Xcode gerekir)

1. Xcode 16 veya üstünü kurun.
2. `ios/AvHaritasi.xcodeproj` dosyasını açın.
3. *AvHaritasi* hedefi → **Signing & Capabilities** → **Team** olarak Apple kimliğinizi seçin
   (ücretsiz Apple ID yeterli; gerekirse *Bundle Identifier*'ı benzersiz bir değerle değiştirin, ör. `com.adiniz.avharitasi`).
4. iPhone'u kabloyla bağlayıp hedef olarak seçin ve ▶︎ ile çalıştırın.
   İlk seferde iPhone'da *Ayarlar → Genel → VPN ve Aygıt Yönetimi* altından geliştiriciye güvenin
   ve *Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu*'nu açın.
5. Uygulama açılınca konum iznine **"Uygulamayı Kullanırken"** deyin. Arka plan uyarısı için
   Ayarlar ekranından *Arka planda takip ve bildirim*'i açın ve bildirim iznini verin.

Ücretsiz Apple ID ile yüklenen uygulama 7 gün sonra yeniden Xcode'dan yüklenmelidir
(ücretli geliştirici hesabında 1 yıl).

## Yeni sezon / başka il haritası

Haritayı [avlakharitalari.tarimorman.gov.tr](https://avlakharitalari.tarimorman.gov.tr) adresinden indirin ve:

```bash
pip install pymupdf numpy scipy pillow
python3 tools/generate_assets.py maps/YENI_HARITA.pdf \
    --name istanbul_2024_2025 --title "İstanbul Avlaklar Haritası" --season "2025-2026" \
    --out ios/AvHaritasi/MapData --preview docs/siniflandirma_onizleme.png
```

`--name` değerini değiştirirseniz `AppModel.swift` içindeki `resourceName`'i de güncelleyin.
Ardından **önizleme görüntüsünü mutlaka orijinal haritayla karşılaştırın**; lejant renkleri farklıysa
`CLASSES` tablosunu düzenleyin.

## ⚠️ Sınırlamalar – lütfen okuyun

- **Uygulama resmi değildir**; yasal sorumluluk avcıya aittir.
- Gömülü harita **2024-2025** sezonuna aittir. İçinde bulunduğumuz sezonun haritası ve Merkez Av Komisyonu
  kararı farklı olabilir — güncel PDF'i indirip yukarıdaki komutla güncelleyin.
- Kaynak, **1:490.000** ölçekli basılı bir haritadır; alan sınırları gerçekte birkaç yüz metre farklı olabilir.
  Bu yüzden uyarı mesafesini 300 m'nin altına düşürmeyin ve turuncu uyarıda temkinli olun.
- Ormanda/engebeli arazide GPS hatası onlarca metreyi bulabilir (uygulama bunu uyarı mesafesine ekler).
- Yeşil durum yalnızca *alanın yasak olmadığını* gösterir; avcılık belgesi, avlanma izin kartı, av günleri,
  türler, kotalar ve yerleşim/yol mesafesi gibi diğer kurallar geçerlidir. İstanbul genelinde tüm keklik
  türlerinin avlanması yasaktır.
- Haritada ayrı lejantı olmayan küçük ayrıntılar (ör. tek tek baraj gölleri) ayrı sınıf olarak ayrıştırılmamıştır.

## Dosya yapısı

```
ios/AvHaritasi.xcodeproj      Xcode projesi
ios/AvHaritasi-Info.plist     Konum izinleri ve arka plan konum modu
ios/AvHaritasi/
  AvHaritasiApp.swift
  Model/HuntingMap.swift      Bölge ızgarası, koordinat → bölge, en yakın yasak alan
  Model/TilePack.swift        Karo paketi okuyucu + MapKit katmanı
  Model/Assessment.swift      Kırmızı/turuncu/yeşil değerlendirme
  Model/AppModel.swift        Konum takibi, uyarı ve bildirimler
  Views/                      SwiftUI ekranları
  MapData/                    Üretilmiş harita verisi
tools/generate_assets.py      GeoPDF → uygulama verisi
maps/                         Kaynak PDF haritalar
```
