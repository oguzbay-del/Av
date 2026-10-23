# Sürüm notları

Her sürüm `## vX.Y.Z — YYYY-AA-GG` başlığıyla eklenir; `surum.yml` etiket itilince bu bölümü GitHub Release notu yapar.

## Yayımlanmamış

- Haritaya yakınlaştır / uzaklaştır düğmeleri

## v0.9.0 — 2026-10-23

İlk deneme (beta) sürümü. Yalnızca İstanbul, internetsiz çalışır. Uygulama resmi değildir; yasal sorumluluk avcıya aittir.

### Harita ve uyarılar
- İstanbul 2026-2027 avlak haritası; MAK kararına göre anlık "avlanabilir / dikkat / avlanmayın" durumu
- Yasak alana yaklaşınca titreşimli uyarı (uygulama kapalıyken de); yasak alan ve bayat GPS uyarıları susturulamaz
- Haritada nokta sorgulama, sınıra mesafe, işaretler ve araca yönlendirme, iz kaydı, saha modu ve gece teması
- Kilit ekranı (canlı durum), widget ve Apple Watch

### Av günü
- Bugün ekranı: av günü, av saati, açık türler, hava, rüzgâr ve koku konisi, av defteri
- Kurallar sekmesi: MAK 2026-2027 özetleri, mesafe kuralları, avlak ve izin belgesi

### Kuş tanıma (cihazda)
- **Ses:** BirdNET V2.4, 333 İstanbul türü
- **Fotoğraf:** yeni tür modeli (EfficientNetV2-S, 331 tür) — test fotoğraflarında ilk tahmin %84,6, ilk 3 %93,4;
  avlanamayan kuşu ≥%70 güvenle av türü sanma %0,21; bulanık ve uzak fotoğraflarda belirgin iyileşme
- **Kuş bulucu:** YOLOX-S fotoğrafta kuşu kutuyla bulur; en çok 3 kuş ayrı ayrı tanınır
- **Video:** galeriden video ya da 10 sn çekim; en iyi 10 sn otomatik seçilir, görüntü ve ses sonucu birleştirilir
- Mevsim ön bilgisi; her sonuçta MAK yasal durumu ve "tahmin kesin teşhis değildir" uyarısı
- Belirsiz sonuçta isteğe bağlı çevrimiçi kontrol (BioCLIP 2 / Perch v2; konum gönderilmez; Ayarlar'dan kapatılır)

### Yardım ve geri bildirim
- Kullanım kılavuzu (Ayarlar › Yardım) ve ilk açılış tanıtımı
- Destek sitesi: https://oguzbay-del.github.io/harita-veri/
- Uygulama içi geri bildirim formu (hata, öneri, harita/sınır hatası, yanlış kuş tanıma)

### Gizlilik
- Anonim kullanım istatistiği (TelemetryDeck; kimlik, tam konum ve yasak alan bilgisi gönderilmez; Ayarlar'dan kapatılır)
- Gizlilik politikası: https://oguzbay-del.github.io/harita-veri/gizlilik/

### Bilinen eksikler
- Gerçek cihazda saha testi henüz yapılmadı (`docs/saha_test_protokolu.md`); TestFlight Apple Developer üyeliğini bekliyor
- Gizlilik ve destek metinlerinde iletişim bilgisi yer tutucu

### Lisanslar
BirdNET CC BY-NC-SA 4.0; fotoğraf modeli CC0 / CC BY / CC BY-NC iNaturalist fotoğraflarıyla eğitildi (ticari olmayan
kullanım); YOLOX Apache-2.0.
