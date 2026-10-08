# Simülatör konum senaryoları (GPX)

Bu klasördeki izler `tools/make_gpx.py` ile **uygulamanın kendi harita verisinden**
hesaplanır (elle çizilmez). Klasör `ios/AvHaritasi` dışında olduğu için uygulama
paketine girmez.

```sh
python3 tools/make_gpx.py          # izleri yeniden üretir ve doğrulama raporunu yazar
```

Betik her senaryo için `Assessment.placeChecks` kurallarını Python'da taklit eder
(bölge rasterı, 300 m korunan alan tamponu, ava yasak alana yaklaşma uyarısı,
köy/ilçe/mesire noktaları, KGM/asfalt yollar, OSM katmanı) ve hangi saniyede
hangi seviyenin çıkması gerektiğini yazar. Aşağıdaki tablolar bu çıktıdan
alınmıştır (`--seed 2026`, varsayılan). Harita verisi değişirse betiği yeniden
çalıştırın ve bu dosyadaki sayıları güncelleyin.

Ortak özellikler:

| | |
|---|---|
| Hız | ~1,3 m/s yürüyüş (adım başına ±%6 oynar) |
| Nokta aralığı | 2 s |
| Başlangıç zamanı | 2026-10-07T06:30:00Z (Çarşamba, İstanbul saatiyle 09:30, av günü) |
| GPS gürültüsü | ~1–2 m bağıntılı (AR(1)) gürültü; pusuda ±5 m |
| Uyarı tamponu | Ayarlar'daki varsayılan 300 m |

Her `.gpx` için aynı noktaları içeren bir `.txt` (satır başına `enlem,boylam`) de
vardır; `xcrun simctl location` için.

## Senaryolar ve beklenen davranış

Zamanlar izin başından itibaren `dakika:saniye`dir. "Bildirim" sütunu,
uygulama **arka plandayken** gelen yerel bildirimi; ön plandaysa aynı anda ses +
titreşim (haptic) olur. `AppModel.alertIfNeeded` yalnızca seviye **kötüleşince**
uyarır, tehlikede kalındıkça **2 dakikada bir** hatırlatır. İyileşmede (tehlike →
dikkat → güvenli) bildirim gelmez, yalnızca bant değişir.

### 01 — Yasak alana giriş (`01_yasak_alana_giris.gpx`)

Sarıkavak bölgesi. Devlet avlağı içinden, en yakın **Ava Yasak Alan** (sınıf 4)
sınırına dik yürür, 200 m içeri girer, aynı hattan geri çıkıp sınırın 400 m dışında biter.

- Başlangıç `41.02446, 29.65804` (devlet avlağı, yasak sınıra 800 m)
- Sınır geçişi (vektör) `41.02066, 29.64993` — başlangıçtan **800 m**; uygulamanın
  rasterında 794 m (fark 6 m)
- En derin nokta `41.01971, 29.64790` — sınırın 199 m içi

| Zaman | Bant | Bildirim |
|---|---|---|
| 00:00 | Yeşil — Avlanabilirsiniz | — |
| ~06:22 | Sarı — "Ava yasak alana 300 m" | ⚠️ dikkat |
| ~10:08 | Kırmızı — "AVLANMAYIN: Ava Yasak Alan" | ⛔️ tehlike |
| ~12:08, ~14:08 | Kırmızı | ⛔️ hatırlatma (2 dk'da bir) |
| 12:50 | (dönüş noktası) | |
| ~15:32 | Sarı — "Ava yasak alana 20 m" | yok (iyileşme) |
| ~19:18 | Yeşil | yok |

Kabul: kırmızı bant sınır geçişinden en geç birkaç saniye sonra (simülatörde ≤ 1–2
nokta, yani ≤ 4 s / ≤ 5 m) görünmeli.

### 02 — Sınır boyunca (`02_sinir_boyunca.gpx`)

Aynı yasak alanın kuzey kenarında, sınırın **dışında** ~2,2 km'lik bir taban hat
boyunca yürür; hat sınırdan 150 m uzaktadır, üzerine ±60 m (400 m dalga boyu)
salınım eklenmiştir.

- Başlangıç `41.03182, 29.63986`, bitiş `41.04014, 29.62140`
- Sınıra uzaklık: min **81 m**, ortalama **152 m**, maks **217 m**; hiçbir noktada içeri girilmez

| Zaman | Bant | Bildirim |
|---|---|---|
| 00:00 – 35:34 | Sarı — "Ava yasak alana ~80–220 m" | ⚠️ yalnızca başta bir kez |

Kabul: tüm iz boyunca **kırmızı hiç çıkmamalı** (yanlış alarm yok), sarı hiç
kesilmemeli (yeşile dönüp tekrar sarı olup bildirim yağdırmamalı).

### 03 — Köy yakını (`03_koy_yakini.gpx`)

**Dereli** köy noktasına (`41.06945, 29.64933`) 210° yönünden 1000 m'den 100 m'ye
yaklaşır, sonra 70° sapan bir yönde 1000 m uzaklaşır. Yol, OSM, korunan alan vb.
başka hiçbir kural iz boyunca tetiklenmez (betik bunu denetler).

| Zaman | Bant | Bildirim |
|---|---|---|
| 00:00 | Yeşil | — |
| ~02:30 | Sarı — "Dereli 800 m" (köy evleri yayılır uyarısı, 300+500 m) | ⚠️ dikkat |
| ~08:58 | Kırmızı — "Dereli 300 m" (Madde 8/7) | ⛔️ tehlike |
| ~10:58, ~12:58, ~14:58 | Kırmızı | ⛔️ hatırlatma |
| 11:36 | En yakın nokta: 98 m | |
| ~15:00 | Sarı — "Dereli 310 m" | yok |
| ~21:32 | Yeşil | yok |

### 04 — Korunan alan tamponu (`04_korunan_alan_tamponu.gpx`)

Özel kanunla korunan alanın (sınıf 3) sınır noktası `41.11469, 29.35855`'e dışarıdan
1000 m'den yaklaşır, sınırın **150 m** yakınına (`41.11518, 29.35688`) gelir, 60° sapan
yönde 1000 m uzaklaşır. Alanın içine hiç girmez; 300 m tampon (Madde 9) içinde
avlanmak yasak olduğu için doğru sonuç **kırmızı**dır.

- Vektöre göre en kısa uzaklık **151 m** (shapely ile de 151 m); uygulamanın
  rasterında aynı noktada 129 m (raster hücresi ~26×34 m)

| Zaman | Bant | Bildirim |
|---|---|---|
| 00:00 | Yeşil | — |
| ~08:40 | Kırmızı — "Özel Kanunlarla Korunan Alan sınırına 300 m" | ⛔️ tehlike (sarı ara aşama yok) |
| ~10:40, ~12:40 | Kırmızı | ⛔️ hatırlatma |
| 10:56 | En yakın nokta (~130–150 m) | |
| ~13:46 | Yeşil | yok |

### 05 — GPS kesintisi (`05_gps_kesintisi.gpx`)

01 ile aynı hat. Sınırın **100 m dışında** son konum (09:02) verilir, sonra **182 s
hiç nokta yoktur**; yürüyüş sürdüğü için konum, sınırın **133 m içinde**
(`41.02001, 29.64856`) geri gelir (12:04).

| Zaman | Bant | Bildirim |
|---|---|---|
| ~06:22 | Sarı — "Ava yasak alana 300 m" | ⚠️ dikkat |
| 09:02 – 12:04 | (konum yok) | — |
| 12:04 | Kırmızı — ilk yeni konumda hemen | ⛔️ tehlike |
| ~14:04 | Kırmızı | ⛔️ hatırlatma |
| ~15:34 | Sarı | yok |
| ~19:24 | Yeşil | yok |

Gözlenecekler:
- Kesinti süresince bant son değerlendirmeyi (sarı) gösterir. Uygulama 30 s'den eski
  ölçümleri yok sayar (`AppModel.didUpdateLocations`); kesintiden sonra ilk taze
  konumla **beklemeden** kırmızıya geçmeli, eski konumla "güvenli" kalmamalı.
- Konum bayatken (ör. > 60 s) arayüzün bunu belirtip belirtmediğini not edin
  (istenen davranış: "Konum güncel değil" uyarısı; yoksa hata kaydı açın).
- **Önemli:** Xcode GPX oynatımı iki nokta arasını zamanla **enterpole edebilir**; bu
  durumda kesinti yerine 3 dakikalık yavaş bir yürüyüş görülür ve test anlamını
  yitirir. Gerçek kesinti için aşağıdaki iki parçalı `simctl` yöntemini kullanın.

### 06 — Hareketsiz pusu (`06_hareketsiz_pusu.gpx`)

Şile tarafında, devlet avlağı içinde `41.10000, 29.53000` noktasında 10 dakika ±5 m
titreşimle bekler, sonra kuzeye 300 m yürür. En yakın yasak/korunan alan **3 km'den
uzak**; köy, yol, OSM kuralı tetiklenmez — bant baştan sona **yeşil** kalır.

| Zaman | Beklenen |
|---|---|
| 00:00 | Yeşil — Avlanabilirsiniz |
| ~03:00 | Durum satırında "pusu: pil tasarrufu" (`updatePowerMode`: 3 dk boyunca < 20 m, yasağa > 600 m → `desiredAccuracy` 10 m, `distanceFilter` 15 m) |
| 10:00 | Yürüyüş başlar |
| ~10:15 | ~20 m hareketten sonra "pusu" yazısı kalkar, tam hassasiyete dönülür |
| 13:52 | Bitiş — hiç bildirim yok |

## Xcode'da kullanma

1. Şemayı çalıştırın (Run). Şemada `Allow Location Simulation` açık olmalı
   (paylaşılan `AvHaritasi.xcscheme`'de açık).
2. Çalışırken **Debug › Simulate Location › Add GPX File to Project…** ile bir `.gpx`
   seçin; açılan pencerede **"Add to targets" kutularını boş bırakın** (dosya
   pakete girmesin). Sonra aynı menüden senaryoyu seçin. Hata ayıklama çubuğundaki
   konum okuyla da (⌖) değiştirilebilir.
3. Her çalıştırmada aynı senaryo isteniyorsa: **Product › Scheme › Edit Scheme… › Run ›
   Options › Default Location** → GPX dosyası. (Bu şema dosyasını değiştirir; kişisel
   bir şema kopyasında yapın, paylaşılan şemayı commit'lemeyin.)
4. Simülatörde konum izni **Her Zaman**, **Kesin Konum açık** olmalı; bildirim izni verin.
   Arka plan davranışı için uygulamayı ana ekrana atın (⇧⌘H) ya da ekranı kilitleyin (⌘L).
5. Zaman kuralları gerçek saate göre değerlendirilir (GPX'teki zaman cihaz saatini
   değiştirmez). Bandın zaman yüzünden kırmızı olmaması için ya **Ayarlar › "Zaman
   kurallarını da değerlendir"** kapatılır ya da Debug derlemesinde saat sabitlenir:
   `xcrun simctl spawn booted defaults write com.example.avharitasi debugNow -string "2026-10-07T06:30:00Z"`
   (bildirimler zaten yalnızca mekânsal seviyeye göre verilir).

Not: Xcode'un oynatma hızı GPX zaman damgalarına uyar; nokta aralığı 2 s olduğu için
beklenen zamanlar ±2–4 s sapabilir.

## Komut satırından (`xcrun simctl location`)

```
xcrun simctl location <cihaz> start [--speed=<m/s>] [--distance=<m> | --interval=<s>] <enlem,boylam>... | -
xcrun simctl location <cihaz> set <enlem,boylam>
xcrun simctl location <cihaz> clear
```

`start`, noktalar arasında verilen **hızla** gider (GPX'teki zamanları kullanmaz);
`-` noktaları standart girdiden okur. `--interval=2` her 2 s'de bir konum güncellemesi üretir.

```sh
cd ios/TestData/GPX
# 01–04: düz oynatma
xcrun simctl location booted start --speed=1.3 --interval=2 - < 01_yasak_alana_giris.txt

# 05: gerçek kesinti (iki parça + 3 dk boşluk)
xcrun simctl location booted start --speed=1.3 --interval=2 - < 05_gps_kesintisi_a_kesinti_oncesi.txt
# ...ilk parça bitince (~9 dk):
xcrun simctl location booted clear     # konum akışı durur
sleep 180
xcrun simctl location booted start --speed=1.3 --interval=2 - < 05_gps_kesintisi_b_kesinti_sonrasi.txt

# 06: simctl "bekleme" bilmez; sabit konum + 10 dk + yürüyüş parçası
xcrun simctl location booted set 41.100000,29.530000
sleep 600
xcrun simctl location booted start --speed=1.3 --interval=2 - < 06_hareketsiz_pusu_yuruyus.txt
```

`set` ile verilen sabit konumda ±5 m titreşim yoktur; titreşimli pusu için Xcode'da
`06_hareketsiz_pusu.gpx` kullanın. (Tam `06_hareketsiz_pusu.txt` dosyasını `start --speed=1.3`
ile oynatmak titreşim noktalarını yürüyüş gibi gezer; pusu testi için uygun değildir.)

`simctl` hızla oynattığı için 05 dışında zamanlar GPX ile yaklaşık aynıdır
(GPS gürültüsü yolu biraz uzattığından ±%10).

## Dosyalar

| Dosya | Nokta | Süre |
|---|---|---|
| `01_yasak_alana_giris.gpx/.txt` | 617 | 20:32 |
| `02_sinir_boyunca.gpx/.txt` | 1068 | 35:34 |
| `03_koy_yakini.gpx/.txt` | 722 | 24:02 |
| `04_korunan_alan_tamponu.gpx/.txt` | 688 | 22:54 |
| `05_gps_kesintisi.gpx/.txt`, `_a_kesinti_oncesi.txt`, `_b_kesinti_sonrasi.txt` | 531 | 20:40 (182 s boşluk dahil) |
| `06_hareketsiz_pusu.gpx/.txt`, `_yuruyus.txt` | 417 | 13:52 |

Saha protokolü: [`docs/saha_test_protokolu.md`](../../../docs/saha_test_protokolu.md).
