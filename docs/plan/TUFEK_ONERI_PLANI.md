# Tüfek, şok ve saçma öneri motoru — çalışma planı

Bu dosya işin **tek takip kaynağıdır**. Oturum ya da token biterse yeni oturum bu dosyayı okuyup ilk işaretlenmemiş
adımdan devam eder. Her aşama bitince ilgili kutu `[x]` yapılır, "Durum günlüğü"ne bir satır eklenir ve PR birleşir.

Sahibin kararları (2026-11): sahibinden ara onay beklenmez; tablo araştırılır, tasarım yapılır, motor kurulur.
Yalnızca internetsiz çalışır. Marka listesi yok; tüfek özellikleri ve sahip olunan şoklar yeterli.
Kaynak notlar: sahibinin derlediği "Türkiye'deki Av ve Spor Tüfekleri Teknik Özellik Uzayı" (bu dosyanın sonunda özet).

## Amaç

Kullanıcı en çok **6 tüfeğini** girer. Ava çıkarken avlayacağı türü/türleri seçer (bugün açık ve bulunduğu yerde yasal
olanlardan). Uygulama **1. ve 2. tercih tüfeği**, her namlu için **şoku**, **saçma numarası + gramajı** (kurşun / çelik)
ve kısa gerekçeyi önerir; uygun tüfek yoksa ne eksik olduğunu söyler. Kara avı (tavşan, tilki, çakal, yaban domuzu)
dahil. Ayrıca çevrimdışı başvuru tablosu ve ava hazırlık kontrol listesi.

## Sert kurallar (asla ihlal edilmez; MAK 2026-27 + güvenlik)

1. İstanbul'da keklik grubu (kınalı, kum, çilkeklik) yasak → listede çıkmaz (`provinceBannedSpecies`).
2. Yalnızca o gün sezonu açık türler (`groups` tarihleri) önerilir; kapalı tür seçilemez.
3. Domuz avında yalnızca tek kurşun (ya da yivli) bulundurulur (MAK 10/1-ı: "tek kurşunlu fişekler dışında başka
   fişek bulundurulması ve kullanılması yasaktır"). Domuz dışındaki türlere tek kurşun ihtiyatla hiç önerilmez
   (yasal iddia değil, "uygun değil"). Domuz, saçma gerektiren türlerle aynı avda seçilemez.
4. Yivli tüfek kuş ve tavşanda kullanılamaz (MAK 10/1-ğ); domuz/tilki/çakalda serbest.
5. Hazne 2 fişek (2+1) — yarı otomatik/pompalıda takoz hatırlatması.
6. Fişek boyu > yatak boyu ise o fişek **önerilmez** (76 mm fişek 70 mm yatakta atılmaz).
7. Çelik saçma: tüfek "çelik saçmaya uygun" değilse çelik önerilmez; çelikte 1 (Full) ve 2 (IM) şok önerilmez
   (iri çelikte en dar 3/Modified), üretici izni yoksa.
8. Tek kurşun asla 1/2 numara dar şokla; silindir (5), IC (4) ya da paradoks/yivli şok.
9. Korunan türler hiçbir zaman hedef olarak sunulmaz (`protectedLatin`).
10. Öneriler başlangıç noktasıdır: ekranda "tüfeğinizi 30–35 m'de patern tahtasında deneyin" ve yasal sorumluluk notu.

## Aşamalar

### A. Araştırma ve bilgi tablosu — `ios/AvHaritasi/Hunting/Data/AvMuhimmat.json` + `docs/AV_MUHIMMAT.md`
- [x] Türk saçma numarası ↔ çap (mm) tablosu (kurşun; çelik numaralandırması ayrı ise belirt), kaynaklı.
- [x] Şok numaraları 1–5 ↔ Full/IM/M/IC/Cyl, tipik daralma, etkili mesafe; paradoks/yivli şok.
- [x] Çelik ↔ kurşun eşdeğerliği (çelik ~2 numara iri), çelik + şok kuralları, bizmut/tungsten notu.
- [x] Sulak alanda kurşun saçma yasağının Türkiye'deki durumu (MAK/yönetmelik) — doğrula, kaynakla; yoksa
      "etik öneri" olarak yaz.
- [x] İri saçma (şevrotin) ve tilki/çakal avında yasal durum; domuz için tek kurşun + yivli kalibre önerileri.
- [x] Her avlanabilir İstanbul türü için: tipik mesafe, arazi, kurşun saçma no (birincil/alternatif), çelik saçma no,
      gramaj aralığı, 1. ve 2. atış şoku, uygun kalibreler, minimum enerji/pelet notu, isabet bölgesi ve etik not
      (ör. ördekte kafa-boyun-ön göğüs; domuzda omuz/kalp-akciğer; uçan kuşa önden), kaynaklar.
- [x] `docs/AV_MUHIMMAT.md`: okunabilir tablo + kaynak listesi + belirsizlikler.

### B. Model ve öneri motoru (saf mantık, birim testli) — `ios/AvHaritasi/Hunting/`
- [x] `Firearm` modeli: ad, tip (yarıOtomatik/pompalı/süperpoze/çifte/tekKırma/yivli), kalibre, yatak (70/76/89),
      namlu boyu, şok sistemi (sabit [hangileri] / mobil [sahip olunanlar 1–5, paradoks]), çeliğe uygun (evet/hayır/
      bilinmiyor), ağırlık sınıfı (isteğe bağlı), yivli kalibre.
- [x] `FirearmStore`: en çok 6, yalnızca cihazda (Application Support, iCloud yedeğinden hariç), istatistik yok.
- [x] `AmmoAdvisor`: girdiler (türler, arazi isteğe bağlı, tüfekler, bugün, konum/avlak yasal durumu) → sıralı öneriler.
      Önce sert kurallar (eleme + gerekçe), sonra puan: şok sahipliği (tam > komşu > yok), kalibre uygunluğu,
      yatak/magnum ihtiyacı, namlu-arazi uyumu, ağırlık-yürüyüş. Çoklu tür seçilince ortak en iyi tek öneri.
      Uygun yoksa "eksik": ör. "Kaz için 76 mm yatak veya 2 numara şok".
- [x] Testler: her sert kural için en az bir test; tipik senaryolar (çulluk + süperpoze 4/5; ördek + 70 mm + çelik
      uygun değil; domuz + yivli; keklik İstanbul → yok; 6 tüfek sınırı).

### C. Ekranlar ve akışlar (SwiftUI, Liquid Glass ile uyumlu, Türkçe + en.json)
- [x] **Tüfeklerim** (Ayarlar › Tüfeklerim ve Hazırlık ekranından): liste (en çok 6), boş durum açıklaması,
      ekle/düzenle formu (adım adım: tip → kalibre/yatak → namlu → şoklar [çip seçimi 1–5, paradoks] → çelik uygunluğu),
      gizlilik notu "yalnızca bu telefonda".
- [x] **Ava hazırlık** (Bugün ekranından kart/düğme): tür seçimi (bugün açık + yasal olanlar, gruplu; karma seçim),
      arazi seçimi isteğe bağlı (orman/çalı · açık mera · sulak alan · geçit) → sonuç kartları:
      1. tercih (büyük kart: tüfek adı, namlu başına şok rozetleri, saçma no + mm + gramaj, kurşun/çelik, gerekçe),
      2. tercih (küçük kart), uyarılar (sert kural notları), "Neden bu?" açılır açıklama.
- [x] **Kontrol listesi**: takoz 2+1, av tezkeresi/avcılık belgesi, avlak izni (devlet avlağındaysa), günlük limitler
      (seçilen türler), önerilen fişek kutuları; işaretlenebilir, gün için hatırlanır.
- [x] **Başvuru tablosu** (Kurallar sekmesi veya Yardım): tür → saçma/şok/mesafe, saçma no ↔ mm, şok no ↔ ad.
- [ ] Av defterine isteğe bağlı "tüfek + fişek" alanı (yalnızca cihazda). — ertelendi (isteğe bağlıydı; av defteri
      kaydı + düğmesiyle tek dokunuşta yapılıyor, alan eklemek düzenleme ekranı gerektirir).
- [x] Erişilebilirlik (VoiceOver, Dynamic Type), saha modunda büyük yazı/opak kartlar.

### D. Belgeler, kılavuz, sürüm
- [x] Kilavuz.json yeni konular (+en), `python3 tools/kilavuz.py`; ekran dosyaları kılavuzda.
- [x] Gizlilik: tüfek bilgisi cihazda kalır → GIZLILIK/PRIVACY/YAYIN bir cümle; PrivacyInfo değişmez.
- [x] CHANGELOG "Yayımlanmamış". Ekran görüntüleri: `appstore-ekran.yml` kume=tufek (9 sahne, `-tufekDemo`).

## Çalışma kuralları
- CLAUDE.md'ye uy (Türkçe, L()/LD(), l10n 0/0, kilavuz --check, akis_denetim, Swift paketi yok).
- Her aşama ayrı PR; CI yeşil olunca birleştir; bu dosyadaki kutuları aynı PR'da işaretle.
- Bilgi tablosu kaynaklı olmalı; emin olunmayan değer "doğrulanmadı" diye işaretlenir, sert kurala dönüştürülmez.

## Durum günlüğü
- 2026-11-05: Plan yazıldı. Sıradaki: A (araştırma).
- 2026-11-05: A bitti (PR #54): `Hunting/Data/AvMuhimmat.json` (30 tür, 16 saçma no, şevrotin, şoklar, çelik, arazi,
  8 yasal bilgi), `docs/AV_MUHIMMAT.md`, denetim `tools/av_muhimmat_denetim.py` (lint.yml › muhimmat). Bulgular:
  Türk saçma no = İtalyan/kıta düzeni (7 ≈ 2,5 mm, 9 ≈ 2,1 mm; üretici farkı ±0,1–0,2 mm, kutudaki mm esas);
  sulak alanda kurşun saçma yasağı **yok** (MAK, Sulak Alan Yönetmeliği, Türkiye AEWA tarafı değil) → etik öneri;
  MAK 10/1-ı "domuz avında yalnız tek kurşun" der, "domuz dışında tek kurşun yasak" demez (keyRules metni ters
  özetliyor, ayrı PR'da düzeltilmeli; motor yine ihtiyatlı kural 3'ü uygular); şevrotin tilki/çakalda MAK'ta
  düzenlenmemiş (doğrulanmadı). Düşük güven: kargagiller, karabatak, saksağan; şevrotin çapları. Sıradaki: B (motor).
- 2026-11-05: B bitti: `Hunting/Domain/` (Firearm, AmmoKnowledge, AdvisorTypes, AmmoAdvisor, PrepChecklist),
  `Hunting/Data/FirearmStore.swift` (en çok 6, Application Support/tufekler.json, yedekten hariç); testler
  AmmoAdvisorTests (28), FirearmStoreTests, PrepChecklistTests. keyRules "Yasak tüfek ve fişek" MAK 10/1-ı lafzına
  göre düzeltildi (domuz avında yalnız tek kurşun). Kullanım istatistiğine yalnızca `tufek_onerisi` sayacı eklendi.
  Sıradaki: C (ekranlar) + D (kılavuz, gizlilik, CHANGELOG).
- 2026-11-05: B birleşti (PR #55). C+D yazıldı: `Hunting/Presentation/` (FirearmViews: Tüfeklerim + 6 adımlı form;
  HuntPrepView: Bugün › Ava hazırlık, tür seçimi, arazi, 1./2. tercih kartları, uyarılar, Neden bu?, nişan/etik;
  PrepChecklistView; AmmoReferenceView: Kurallar › başvuru tablosu; HuntingComponents). Kılavuzda yeni bölüm
  "Tüfek ve fişek" (4 konu), gizlilik belgeleri, CHANGELOG. AvMuhimmat.json gösterilen alanları l10n'a eklendi.
  Ekran görüntüsü kümesi: appstore-ekran.yml kume=tufek. Sıradaki: C+D PR'ı CI yeşil → birleştir; ekran görüntülerini
  incele ve gerekirse yerleşimi düzelt. Açık: av defterine tüfek/fişek alanı (ertelendi).

## Ek: sahibinin notlarından özet
Mekanizma (yarı otomatik kinetik/gazlı/kutulu, pompalı, süperpoze, çifte, tek kırma, lever, bolt), kalibre (12/20/28/
.410/16; yivli .308/30-06/6.5 CM), yatak 70/76/89 mm, namlu 48–81 cm, şerit tipleri, şoklar (mobil 1–5, uzatmalı,
sabit, paradoks), şarjör (avda 2+1), kundak, nişangah, ağırlık sınıfları. Şok tablosu: 1 Full 40–50 m, 2 IM 35–45 m,
3 M 30–40 m, 4 IC 20–30 m, 5 Cyl 10–20 m. Av türüne göre kaba öneriler (çulluk/bıldırcın 20–12 Ga, 61–66 cm, 4–5;
keklik/tavşan 12 Ga 66–71 cm 3–4; ördek/kaz 12 Ga 76/89 mm 71–76 cm 1–2; domuz 12 Ga 48–61 cm slug/cyl/paradoks).
