# Av Haritası — Saha Test Protokolü

Amaç: Uygulamanın, avcı yasak alana girdiğinde ya da yasal mesafe kurallarının
(300 m korunan alan tamponu, köy/yerleşim, KGM yolu) içine düştüğünde **zamanında
ve doğru yerde** uyardığını; uygulama kapalıyken, çevrimdışıyken ve zayıf GPS'te
de güvenilir kaldığını ve pili makul tükettiğini sahada ölçmek.

Kapsam: İstanbul 2026–2027 haritası, iOS 17+ (CLMonitor), uygulama sürümü ve
derleme numarası her kayıtta yazılır.

---

## 1. Simülatör ön testi (sahaya çıkmadan)

Sahaya gitmeden önce her derleme için `ios/TestData/GPX/` senaryoları simülatörde
oynatılır (kullanım: `ios/TestData/GPX/README.md`). Beklenen zamanlar o dosyadaki
tablolardadır; sapma > 5 s ise sahaya çıkılmaz, önce hata giderilir.

| GPX | Denetlenen | Saha karşılığı |
|---|---|---|
| `01_yasak_alana_giris` | Yasak alana giriş, 300 m ön uyarı, 2 dk hatırlatma | T1, T2, T3 |
| `02_sinir_boyunca` | Sınıra paralel yürüyüşte yanlış alarm olmaması | T4 |
| `03_koy_yakini` | Köy 800 m dikkat / 300 m yasak | T5 |
| `04_korunan_alan_tamponu` | Korunan alanın 300 m tamponu | T6 |
| `05_gps_kesintisi` | Konum kesintisi sonrası hemen doğru seviye | T9 |
| `06_hareketsiz_pusu` | Pusu modu (pil tasarrufu) ve çıkışı | T10, B1 |

İzler `python3 tools/make_gpx.py` ile yeniden üretilebilir; betik sınır geçişini ve
mesafeleri uygulamanın verisiyle doğrular.

---

## 2. Ekipman

| # | Cihaz | Ayar | Görev |
|---|---|---|---|
| C1 | Güncel iPhone (ör. iPhone 15/16) | Düşük Güç Modu **kapalı** | Referans cihaz; ön plan + arka plan takibi |
| C2 | Eski iPhone (ör. iPhone XS/11, iOS 17) | Düşük Güç Modu **açık** | En kötü durum: kısıtlı arka plan, eski GPS yongası |
| C3 | Herhangi bir iPhone (+ eşli Apple Watch, varsa) | Düşük Güç Modu kapalı, **uygulama kapalı** (kaydırılarak kapatılmış) | Kapalı uygulama / geofence uyarısı; Live Activity ve saat |

Ek ekipman:
- Referans GPS kaydedici (Garmin el GPS'i ya da üçüncü bir telefonda 1 s aralıklı
  GPX kaydeden uygulama) — "gerçek" sınır geçiş anını belirlemek için.
- Sınır noktaları önceden işaretlenmiş çevrimdışı harita (referans cihazda), kâğıt harita.
- Kronometre (ya da referans GPS'in saat damgası); tüm cihazların saati otomatik (NTP) olmalı.
- Powerbank, kablolar; pil testinde cihazlar **şarja bağlanmaz**.
- Test formu (bölüm 10'daki CSV) — tablet ya da kâğıt.
- Güvenlik: av sezonunda turuncu yelek; ekip en az 2 kişi; yasak alana girişler
  **silahsız** ve yalnızca test amaçlı, kısa süreli yapılır; mülk sınırlarına uyulur.

---

## 3. Ön kontroller (her cihaz, her test günü)

| # | Kontrol | Nasıl | Beklenen |
|---|---|---|---|
| K1 | Konum izni | Ayarlar › Gizlilik ve Güvenlik › Konum Servisleri › Av Haritası | **Her Zaman** |
| K2 | Kesin Konum | Aynı ekran | **Açık** (kapalıysa uygulama "Kesin Konum kapalı" kırmızı uyarısı vermeli) |
| K3 | Bildirimler | Ayarlar › Bildirimler › Av Haritası | İzin açık, Kilit Ekranı + Bildirim Merkezi + Afişler, **Sesler açık**, **Zamana Duyarlı** açık |
| K4 | Odak modları | Denetim Merkezi | Rahatsız Etme / Odak kapalı (ya da Av Haritası izinli listesinde) |
| K5 | Arka planda uygulama yenileme | Ayarlar › Genel | Açık (C2'de Düşük Güç Modu bunu kısıtlar — not edin) |
| K6 | Uygulama ayarları | Uygulama › Ayarlar | "Uygulama kapalıyken de uyar" açık, "Arka planda sürekli takip" teste göre, uyarı mesafesi 300 m, "Durumu kilit ekranında göster" açık |
| K7 | Zaman kuralları | Uygulama › Ayarlar | Av günü dışında test yapılıyorsa "Zaman kurallarını da değerlendir" **kapalı** (aksi hâlde bant her yerde kırmızı olur) |
| K8 | Harita verisi | Uygulama › Hakkında / bant | 2026–2027 haritası yüklü, sezon doğru |
| K9 | Sessiz mod / ses | Yan tuş, ses seviyesi | Ses %50+, sessiz mod kapalı (sessizde yalnız titreşim beklenir — ayrıca test edin) |
| K10 | Pil | Ayarlar › Pil | %100'e şarj, ölçüm başlangıç değeri yazılır |
| K11 | Saat | Ayarlar › Genel › Tarih ve Saat | Otomatik |
| K12 | Saha kaydı | Uygulama › Ayarlar › Gelişmiş › Tanı raporları | **Saha kaydı** testten önce elle **açılır** (varsayılan kapalı; bkz. §11a) |

---

## 4. Test alanları

Rotalar, simülatör senaryolarıyla aynı yerlerde seçilir; böylece saha ölçümü
beklenen değerlerle karşılaştırılabilir:

| Alan | Konum | Kullanım |
|---|---|---|
| A — Sarıkavak yasak alan sınırı | Başlangıç `41.02446, 29.65804` → sınır `41.02066, 29.64993` | T1–T4, T7–T9 |
| B — Dereli köyü | Köy noktası `41.06945, 29.64933` | T5 |
| C — Korunan alan sınırı | Sınır noktası `41.11469, 29.35855` | T6 |
| D — Şile devlet avlağı, yasaklardan > 3 km | `41.10000, 29.53000` | T10, B1–B3 (pil) |
| E — Orman içi vadi (dere yatağı, sık ağaç) | A alanının yakınında, sınırı kesen bir dere vadisi seçilir | T11 |

Sahada sınırın gerçek yeri bilinemez; "sınır geçişi" = **uygulamanın kullandığı
harita sınırı** (referans GPS izinin haritadaki sınırla kesiştiği an). Haritanın kendi
sınır hassasiyeti birkaç yüz metredir; bu protokol uygulamanın tepkisini ölçer,
haritanın doğruluğunu değil.

---

## 5. Test vakaları

Ölçülecekler: **uyarı mesafesi** (uyarı anında referans GPS konumunun sınıra/kurala
uzaklığı; içerideyse "+", dışarıdaysa "−" işaretli), **gecikme** (sınır/kural çizgisinin
geçildiği andan uyarıya kadar geçen saniye), bildirim/bant/ses/titreşim gözlemi.

| ID | Kurulum | Adımlar | Beklenen | Ölçülen: uyarı mesafesi / gecikme | Geçti/Kaldı |
|---|---|---|---|---|---|
| T1 | C1, uygulama **ön planda**, ekran açık | A alanında sınıra 800 m'den dik yürü, 200 m içeri gir, geri çık | 300 m kala sarı bant + ⚠️ ses/titreşim; sınırda kırmızı + ⛔️ ses/titreşim; içeride 2 dk'da bir hatırlatma; çıkışta sarı → yeşil (bildirimsiz) | | |
| T2 | C1, "Arka planda sürekli takip" açık, uygulama **arka planda**, ekran kilitli, telefon cepte | T1 rotası | Kilit ekranında ⚠️ ve ⛔️ bildirimleri, sesli; Live Activity rengi değişir | | |
| T3 | C2 (Düşük Güç Modu açık), T2 kurulumu | T1 rotası | T2 ile aynı; gecikme farkı not edilir | | |
| T4 | C1 + C2, arka planda | A alanında sınıra ~150 m paralel 2 km yürü (±60 m) | Baştan sona sarı; **hiç kırmızı yok**; ⚠️ bildirimi yalnızca bir kez (sarı ↔ yeşil salınımı yok) | yanlış alarm sayısı | |
| T5 | C1, arka planda | B alanında köye 1 km'den 100 m'ye yaklaş, uzaklaş | ~800 m'de sarı "köy … m"; 300 m'de kırmızı (Madde 8/7); 300 m dışına çıkınca sarı | | |
| T6 | C1, arka planda | C alanında korunan alan sınırına 1 km'den 150 m'ye yaklaş, uzaklaş | 300 m'de doğrudan kırmızı "… sınırına 300 m" (sarı ara aşama yok); alanın içine girmeden | | |
| T7 | C3, **uygulama kapalı** (uygulama değiştiricide yukarı kaydırılmış), "Uygulama kapalıyken de uyar" açık | Uygulamayı A başlangıcında bir kez açıp kapat (güvenli daire kurulsun); sonra T1 rotası | Güvenli daireden çıkışta iOS uygulamayı uyandırır; sınıra ~100 m kala ya da en geç girişte ⛔️/⚠️ bildirim | gecikme (dk) | |
| T8 | C3, uygulama kapalı, cihaz **yeniden başlatılmış** ve kilidi bir kez açılmış | T7 | T7 ile aynı (yeniden başlatma sonrası izleme sürmeli) | | |
| T9 | C1, ön planda | A rotasında sınıra 100 m kala telefonu **Faraday kesesine / metal kutuya** koy (ya da Uçak Modu + Konum kapalı), 3 dk yürü, sınırın ~130 m içinde çıkar | Kesinti boyunca bant son değeri gösterir (bayatlık belirtilmeli); konum gelince **ilk taze konumda** kırmızı, 30 s'den eski konumla karar verilmez | ilk doğru uyarıya kadar süre | |
| T10 | C1, D alanı, arka planda | 10 dk kıpırdamadan bekle, sonra 300 m yürü | ~3 dk sonra "pusu: pil tasarrufu"; harekette ~20 m içinde normal moda dönüş | | |
| T11 | C1 + C2, E alanı (vadi) | Vadinin içinden sınırı kesen rota; ağaç altında 5 dk dur | GPS doğruluğu ±150 m'yi aşarsa sarı "GPS doğruluğu düşük"; doğruluk kötüyken yeşil "Avlanabilirsiniz" gösterilmemeli; sınır geçişi T1 ölçütlerine göre (gevşetilmiş, bkz. §11) | doğruluk (m) dağılımı | |
| T12 | C1, Kesin Konum **kapalı** | Uygulamayı aç | Hemen kırmızı "Kesin Konum kapalı" ve ayara yönlendirme | | |
| T13 | C1, Uçak Modu (bkz. §7) | A rotası | Harita ve uyarılar çevrimdışı çalışır | | |
| T14 | C3 + Watch, bkz. §9 | A rotası | Live Activity / Watch bildirimi | | |

Her vaka **en az 3 kez** (T1, T2, T7 için 5 kez) tekrarlanır; her tekrar ayrı CSV satırıdır.

---

## 6. Kapalı uygulama — geofence gecikme testi (T7/T8 ayrıntısı)

Uygulama kapalıyken uyarı, iOS'un "güvenli daire" bölge izlemesine dayanır
(`Geofence.swift`: en yakın yasak alana ~100 m kalacak yarıçapta tek daire, en az
120 m, en çok 3 km). iOS bölge çıkışlarını hücre/Wi-Fi değişimine göre ve
gecikmeli bildirebilir; bu yüzden ölçüm ayrı yapılır.

1. C3'te uygulamayı A başlangıcında aç, konum alınsın, 30 s bekle, uygulamayı
   uygulama değiştiriciden kaydırarak kapat. Saat: **t0**.
2. Rotayı normal yürüyüş hızında izle; referans GPS'te her 100 m'de bir işaret bırak.
3. Bildirim geldiği anı (kilit ekranındaki saat + referans GPS) yaz: **t_uyarı**,
   o andaki konumun sınıra uzaklığı.
4. Ayrıca "güvenli daire" sınırının geçildiği anı hesapla (daire yarıçapı ≈ başlangıçtaki
   sınır uzaklığı − 100 m) → **t_daire**. Gecikme = t_uyarı − t_daire; sınıra göre gecikme
   = t_uyarı − t_sınır.
5. Bildirim hiç gelmezse 200 m içeride 5 dk bekle, sonra uygulamayı aç ve "Kaldı" yaz.
6. Aynı testi C3 yerine C2'de (Düşük Güç Modu açık) bir kez tekrarla.
7. Varyasyonlar: (a) telefon cepte, ekran kapalı; (b) cihaz yeniden başlatılmış (T8);
   (c) hücresel kapsama zayıf yer.

---

## 7. Uçak modu — çevrimdışı harita testi (T13)

1. Evde Wi-Fi'da uygulamayı açıp test alanlarının haritasının göründüğünü doğrula.
2. Sahada **Uçak Modu açık**, Wi-Fi ve Bluetooth kapalı; Konum Servisleri açık kalır
   (GPS uçak modunda çalışır).
3. Uygulamayı kapatıp yeniden aç (soğuk başlatma).
4. Kontroller: harita karoları ve bölge renkleri yükleniyor mu (zoom 8–13), bant
   değerlendirmesi çalışıyor mu, A rotasında T1 beklentileri sağlanıyor mu, hava durumu
   alanı zarif biçimde "alınamadı" diyor mu (çökme / sonsuz yükleme yok).
5. Uçak modunda arka plan takibi ve kapalı uygulama uyarısı (T2, T7) birer kez tekrarlanır.

---

## 8. Pil ölçümü (4 saat)

Üç senaryo, her biri **4 saat**, cihaz şarja takılmadan, ekran parlaklığı %50 sabit,
otomatik kilit 1 dk:

| ID | Cihaz | Uygulama durumu | Hareket |
|---|---|---|---|
| B1 | C1 ve C2 | Ön planda değil, "Arka planda sürekli takip" açık, Live Activity açık | 30 dk yürüyüş + 30 dk pusu döngüsü (D alanı) |
| B2 | C1 ve C2 | Yalnızca "Uygulama kapalıyken de uyar" (geofence), uygulama kapalı | Aynı döngü |
| B3 | C1 | Uygulama yüklü değil / kapalı, konum servisleri açık (taban ölçüm) | Aynı döngü |

Yöntem:
1. Başlangıçta pil %100 ve Ayarlar › Pil yüzdesi yazılır; her **30 dk**'da bir yüzde
   ve ekrandaki "son 24 saat" uygulama payı (Ayarlar › Pil › uygulama listesi) kaydedilir.
2. Ayrıntılı ölçüm için C1'de: Ayarlar › Geliştirici › **Performance Trace** (Power
   Profiler) açılır, test sonunda iz alınıp Mac'te **Instruments › Power Profiler**
   ile açılır; CPU, GPS (Location), ekran ve ağ bileşenleri ayrı not edilir.
   Alternatif: cihaz Mac'e bağlıyken Instruments › Energy Log / Power Profiler ile
   kısa (30 dk) ölçüm.
3. Pusu bölümlerinde "pusu: pil tasarrufu" ifadesinin görüldüğü süre not edilir.
4. Sonuç: saat başına ortalama yüzde tüketimi = (başlangıç − bitiş) / 4; B1 − B3 farkı
   uygulamanın ek tüketimidir.

---

## 9. GPS'in zayıf olduğu arazi (T11 ayrıntısı)

- E alanında (orman içi dere vadisi, yamaç dibi) C1 ve C2 yan yana taşınır.
- Uygulamadaki doğruluk değeri (±m) her 1 dk not edilir (ekran görüntüsü yeterli).
- Beklenen: doğruluk kötüleşince (> 150 m) sarı "GPS doğruluğu düşük" uyarısı;
  mesafe kuralları doğruluk payı eklenerek değerlendirilir (sınıra 300 m + doğruluk
  içinde olunca sarı/kırmızı erken gelir — **erken uyarı kabul, geç uyarı kabul edilmez**).
- Ölçülür: yanlış "güvenli" süresi (gerçekte 300 m tamponda/yasak alanda iken yeşil
  gösterilen süre) — hedef 0.

---

## 10. Live Activity ve Apple Watch (T14)

- C3'te "Durumu kilit ekranında göster" açık; uygulama arka planda.
- Kontroller: kilit ekranında ve Dynamic Island'da durum rengi (yeşil/sarı/kırmızı)
  ve başlık her seviye değişiminde güncelleniyor mu; gecikme bant değişimine göre ≤ 10 s mi;
  30 dk güncelleme olmazsa bayat (stale) görünüm doğru mu (`staleDate` 30 dk).
- Apple Watch (eşli, bilek üstünde, iPhone kilitli ve cepte): ⚠️/⛔️ bildirimleri
  saatte titreşimle görünüyor mu, iPhone'a göre gecikme. (Saat uygulaması yoksa
  yalnızca bildirim yansıması test edilir.)
- iPhone kilidi açıkken saate bildirim gitmemesi normaldir — not edin, "Kaldı" saymayın.

---

## 11. Veri kayıt şablonu (CSV)

Dosya adı: `saha_<tarih>_<cihaz>.csv`, UTF-8, ayraç virgül. Her tekrar bir satır.

```csv
tarih,saat_baslangic,test_id,tekrar,cihaz,ios_surumu,uygulama_surumu,dusuk_guc,uygulama_durumu,arka_plan_takip,geofence,konum_izni,kesin_konum,alan,sinir_lat,sinir_lon,yon,hiz_ms,beklenen_seviye,uyari_seviyesi,uyari_turu,uyari_zamani,sinir_gecis_zamani,gecikme_s,uyari_lat,uyari_lon,uyari_mesafe_m,gps_dogruluk_m,yanlis_alarm_sayisi,kacirilan_uyari,pil_baslangic,pil_bitis,sure_dk,hava,orman_ortusu,sonuc,notlar
2026-10-14,07:10,T2,1,C1,18.1,1.4 (52),hayir,arka_plan,evet,evet,her_zaman,acik,A,41.02066,29.64993,GB,1.3,danger,danger,bildirim+ses,07:20:41,07:20:35,6,41.02060,29.64980,12,5,0,hayir,100,97,15,acik,orta,GECTI,
```

Alan açıklamaları:
- `uygulama_durumu`: `on_plan` / `arka_plan` / `kapali`
- `uyari_turu`: `bant`, `ses`, `titresim`, `bildirim`, `live_activity`, `watch` (birden çoksa `+` ile)
- `uyari_mesafe_m`: uyarı anında sınıra/kurala uzaklık; yasak alanın **içinde** pozitif,
  dışında negatif (ön uyarılarda ör. `-300`)
- `gecikme_s`: `uyari_zamani − sinir_gecis_zamani` (referans GPS'e göre)
- `kacirilan_uyari`: beklenen uyarı hiç gelmediyse `evet`

Ayrıca her test için referans GPS'in `.gpx` kaydı, uygulama ekran kayıtları
(Denetim Merkezi › Ekran Kaydı) ve uygulamanın **saha kaydı** (§11a) saklanır.

---

## 11a. Saha kaydı (uygulamanın kendi olay günlüğü)

Uygulama, sahada ne yaptığını olay olay telefona yazar; böylece "uyarı neden geç geldi /
hiç gelmedi" sorusu, form ve referans GPX ile birlikte uygulamanın gözünden de cevaplanır.

**Açma (ön kontrollere ek, K12):** Uygulama › Ayarlar › Gelişmiş › Tanı raporları › **Saha kaydı**
anahtarını testten **önce** açın. Kayıt tüm derlemelerde (Xcode, TestFlight, App Store) varsayılan
olarak **kapalıdır**; seçim telefonda saklanır, yani bir kez açınca kapatana kadar açık kalır. Yine de
her test günü anahtarın açık olduğunu kontrol edin. Uygulama kilidi (Ayarlar › Gizlilik) açıksa
kaydı açmak/kapatmak, paylaşmak ve silmek Face ID / cihaz parolası ister.

**Kaydedilen olaylar:** uygulama açılışı (sürüm, iOS, Düşük Güç Modu), ön plan/arka plan,
konum ölçümü (4 ondalık koordinat, ±doğruluk, yaş, hız; en çok 10 sn'de bir, doğruluk kademesi
ya da seviye değişince hemen), seviye değişimi (önceki → yeni, başlık), gönderilen uyarı
(seviye, başlık, ön plan / arka plan bildirimi), GPS kesintisi başı/sonu (90 sn), CLError,
GPS kademesi (yakın / uzak / pusu), güvenli daire kuruldu (yarıçap) / çıkış / kaldırıldı,
arka plan konum oturumu, demo modu, hava durumu alındı/alınamadı, internet var/yok,
Live Activity başladı/bitti.

**Her test (ya da test günü) sonunda:**
1. Testin bittiği saati forma yazın (kayıttaki saatlerle eşleştirmek için).
2. Uygulama › Ayarlar › Gelişmiş › Tanı raporları › **Saha kaydını paylaş** → iki dosya:
   `saha_kaydi_<yyyyMMdd-HHmm>.txt` (Türkçe, Europe/İstanbul yerel saati, okunur) ve
   `.jsonl` (her satır bir olay, UTC ISO 8601; betikle işlemek için).
3. AirDrop / Dosyalar ile test klasörüne `saha_<tarih>_<cihaz>_kayit.txt|.jsonl` adıyla kaydedin
   (C1, C2, C3 ayrı ayrı). Mesajlaşma uygulamalarına göndermeyin: kayıt **konum içerir**.
4. Kontrol: T1/T2'de "Seviye … → yasak" ve "UYARI (yasak, …)" satırlarının saati
   `uyari_zamani` ile; T7/T8'de "Güvenli daire kuruldu: … m" ve "Güvenli daireden çıkış"
   satırları geofence gecikmesiyle; T9'da "GPS kesildi" / "GPS geri geldi"; T10'da
   "GPS kademesi: pusu"; T13'te "İnternet yok" satırları karşılaştırılır. Uyarı gelmediyse
   (kaçırılan uyarı) kayıttaki son konum ölçümleri ve seviye satırları hata kaydına eklenir.
5. Bir sonraki teste temiz başlamak isterseniz **Kaydı sil**. Silmezseniz 7 günden eski olaylar
   açılışta (ve uygulama açık kaldıkça günde bir) kendiliğinden silinir.

Sınırlar: bellekte son ~2000 olay; diskte `saha_kaydi.jsonl` 2 MB'ta `saha_kaydi.1.jsonl`'e
döner (toplam en çok ~4 MB, en yüksek hızda ~1,5 gün). Dosyalar
"ilk kilit açmaya kadar" korumasıyla şifrelidir (telefon açıldıktan sonraki ilk kilit açmaya
kadar okunamaz; sonra telefon cepte kilitliyken de yazılır) ve iCloud/iTunes yedeğine alınmaz.
Telefon yeniden başlatılıp henüz kilidi açılmadıysa gelen olaylar bellekte bekletilir ve ilk kilit
açmadan sonra yazılır; uygulama o arada sonlandırılırsa bu olaylar kaybolabilir (kayıtta boşluk
olarak görünür; T7/T8'de not edin).
Aynı olaylar Console.app'te `com.example.avharitasi` alt sistemi, `saha` kategorisiyle de
görünür (cihaz Mac'e bağlıyken; konumlar orada gizlidir).

---

## 12. Kabul ölçütleri

| # | Ölçüt | Eşik |
|---|---|---|
| A1 | **Tehlike uyarısı, ön planda** (T1, T5, T6) | Sınır/kural çizgisi geçildikten sonra **≤ 30 s** ve **≤ 50 m** içinde kırmızı bant + ses/titreşim; 5 tekrarın 5'inde |
| A2 | **Tehlike uyarısı, arka plan takibi** (T2, T3) | ≤ 30 s / ≤ 50 m, kilit ekranında sesli bildirim; C1'de 5/5, C2'de (Düşük Güç) en az 4/5 ve hiçbiri > 60 s değil |
| A3 | **Ön uyarı (dikkat)** (T1, T5) | Ava yasak alana 300 m kala (±50 m), köye 800 m kala (±50 m) sarı; ⚠️ bildirimi |
| A4 | **Kapalı uygulama — geofence** (T7, T8) | Sınır geçişinden sonra en geç **5 dk** içinde bildirim (hedef: sınıra varmadan önce); 5 tekrarın en az 4'ünde; hiç gelmeyen = kritik hata |
| A5 | **Yanlış alarm** (T4, T11) | Sınırdan ≥ 80 m dışarıda yürürken kırmızı uyarı **0**; sarı ↔ yeşil salınımıyla gelen fazladan bildirim ≤ 1/km |
| A6 | **Yanlış güvenli** (tüm vakalar) | Yasak alanda/tamponda yeşil "Avlanabilirsiniz" gösterilen süre **0 s** (GPS kesintisi sonrası ilk taze konum dahil) |
| A7 | **GPS kesintisi** (T9) | Konum geri geldikten sonra ≤ 10 s içinde doğru (kırmızı) seviye; bayat konumla yeşil gösterilmez |
| A8 | **Çevrimdışı** (T13) | Uçak modunda harita, değerlendirme ve uyarılar tam çalışır; çökme yok |
| A9 | **Pil — arka plan takibi** (B1) | C1'de B3 tabanına ek **≤ %4/saat**, C2'de **≤ %6/saat**; 4 saat sonunda C1 ≥ %75 |
| A10 | **Pil — yalnız geofence** (B2) | B3 tabanına ek **≤ %1/saat** |
| A11 | **Pusu modu** (T10) | 3–4 dk durgunluktan sonra devreye girer, ≤ 20–30 m harekette çıkar; pusu süresince yasak alana yaklaşmada uyarı gecikmesi A2 içinde kalır |
| A12 | **Live Activity / Watch** (T14) | Seviye değişiminden ≤ 10 s içinde güncel; saat bildirimi iPhone'dan ≤ 5 s sonra |
| A13 | **Zayıf GPS** (T11) | Doğruluk > 150 m iken sarı "GPS doğruluğu düşük" görünür; A1/A2 eşikleri burada ≤ 60 s / ≤ 100 m olarak gevşetilir |

Bir A1, A2, A4, A6 ihlali **yayını durdurur** (kritik). Diğer ihlaller hata kaydı
olarak açılır ve bir sonraki sürümde yeniden test edilir.

---

## 13. Raporlama

- Her test günü sonunda CSV'ler birleştirilir; vaka başına medyan ve en kötü gecikme,
  uyarı mesafesi, geçme oranı hesaplanır.
- Kaldı olan her satır için: ekran kaydı, referans GPX, saha kaydı (§11a), uygulama sürümü ve (varsa)
  sysdiagnose ile hata kaydı açılır.
- Simülatör ön testi (bölüm 1) ile saha sonuçları arasında > 30 s ya da > 50 m fark
  varsa nedeni (GPS gecikmesi, arka plan kısıtı, harita rasterı) rapora yazılır.
