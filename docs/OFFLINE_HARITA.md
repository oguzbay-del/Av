# Çevrimdışı altlık harita (İstanbul)

Uygulama, internet olmadan da kullanılabilen bir topoğrafik altlık haritasını bir kez indirir.
OSM / OpenTopoMap / Apple karolarını toplu indirmek bu hizmetlerin kullanım koşullarına aykırıdır;
bu yüzden karolar **açık veriden kendi iş akışımızda çizilir** (`tools/render_basemap.py`).

## Sözleşme (uygulama tarafı ile)

| Öğe | Değer |
|---|---|
| Release etiketi | `basemap-istanbul` |
| İndirme adresi | `https://github.com/oguzbay-del/Av/releases/download/basemap-istanbul/<ad>` |
| Manifest | `basemap_manifest.json` |
| Düşük paket | `istanbul_topo_low.avtp`, z8–12, hedef ≤ 15 MB (uygulamaya gömülebilir) |
| Yüksek paket | `istanbul_topo_high.avtp`, z13–15, hedef ≤ 150 MB |
| Karo | 256 px, Web Mercator XYZ (`MKTileOverlay.tileSize = 256`) |

Manifest şeması:

```json
{
  "version": "2026-10-09",
  "attribution": "© OpenStreetMap katkıcıları (ODbL) · Yükselti: Copernicus DEM GLO-30 … · Arazi örtüsü: © ESA WorldCover 2021 …",
  "attributionEn": "© OpenStreetMap contributors (ODbL) · Elevation: … · Land cover: …",
  "tileSize": 256,
  "bounds": [27.95, 40.8, 29.95, 41.6],
  "missingTileColor": "#a9cfe6",
  "files": [
    {"name": "istanbul_topo_low.avtp", "minZoom": 8, "maxZoom": 12, "bytes": 0, "sha256": "…",
     "url": "https://github.com/oguzbay-del/Av/releases/download/basemap-istanbul/istanbul_topo_low.avtp",
     "tiles": 0}
  ]
}
```

`version`, `attribution`, `files[].name/minZoom/maxZoom/bytes/sha256/url` zorunlu alanlardır;
`attributionEn`, `tileSize`, `bounds`, `missingTileColor`, `files[].tiles` ek bilgidir (Codable bunları
yok sayabilir). İndirme sonrası `sha256` doğrulanmalıdır.

### AVTP biçimi

Değişiklik yok; `ios/AvHaritasi/Model/TilePack.swift` ve `tools/generate_assets.py` ile aynı
(little endian):

```
"AVTP" | u32 sürüm=1 | u32 adet |
adet × (u8 z, 3 bayt boşluk, u32 x, u32 y, u64 ofset, u32 uzunluk) | karo verileri
```

Tek fark içerikte: karo verisi **PNG ya da JPEG** olabilir (ilk baytlar `89 50 4E 47` / `FF D8`).
MapKit `loadTile` sonucunda ikisini de doğrudan çözer; `PackTileOverlay`'in büyütme yolu da
`UIImage(data:)` kullandığından Swift tarafında değişiklik gerekmez.

**Eksik karolar:** il sınırının tamamen dışındaki ve tamamen deniz olan karolar pakette yoktur.
Uygulama paket aralığında bulamadığı karo için `missingTileColor` (deniz rengi) ile dolu bir karo
göstermelidir (şeffaf boş karo yerine), aksi hâlde `canReplaceMapContent = true` iken denizde boşluk görünür.
z15 sonrası için mevcut `PackTileOverlay` büyütmesi (`maximumZ = maxZoom + 6`) kullanılabilir.

## Veri kaynakları ve lisanslar

| Kaynak | Kullanım | Lisans / atıf |
|---|---|---|
| OpenStreetMap, Geofabrik `turkey-latest.osm.pbf` | arazi kullanımı, su, kıyı, yollar, demiryolu, enerji hattı, yapılar, yer adları, zirveler, kaynaklar, il sınırı (admin_level=4 "İstanbul") | ODbL 1.0 — "© OpenStreetMap katkıcıları" |
| Copernicus DEM GLO-30 (AWS `s3://copernicus-dem-30m`) | tepe gölgelendirmesi, eş yükselti eğrileri, OSM kutusu dışında kara/deniz ayrımı | Ücretsiz; atıf zorunlu: "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved" |
| ESA WorldCover 2021 v200 (AWS `esa-worldcover`) | OSM'de çizilmemiş orman / çalılık / çayır / tarım / sulak alan dolgusu | CC BY 4.0 — "© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium" |
| DejaVu Sans | etiket yazı tipi (Türkçe karakterler) | Bitstream Vera / DejaVu serbest lisansı (rasterleştirilmiş metinde kısıt yok) |

Uyarılar:

* Karolar ODbL anlamında **"üretilmiş çalışma"dır** (Produced Work): uygulamada görünür atıf
  (`attribution`) şarttır; karoların kendisi paylaşım-aynı koşula tabi değildir, ancak OSM verisinden
  türetilmiş bir *veritabanı* dağıtılırsa (ör. vektör) o ODbL olur.
* WorldCover, istenen atıf metnine eklenmiş üçüncü bir kaynaktır (CC BY 4.0, ticari kullanım serbest,
  atıf zorunlu). İstenmezse `--no-worldcover` ile kapatılır; atıf metni de otomatik kısalır.
* Copernicus GLO-30 bir **yüzey modeli** (DSM) olduğundan ağaç ve yapı yüksekliklerini içerir.
  Orman kenarlarında birkaç metrelik sahte basamaklar olabilir; bunu bastırmak için DEM yumuşatılır
  (genel σ = 1 piksel; z13+ gölgede 40 m, eğrilerde 60 m). Çıplak zemin modeli FABDEM daha doğru olurdu
  ancak CC BY-NC-SA (ticari olmayan) lisanslıdır, App Store uygulaması için kullanılmadı.
* Eş yükselti eğrileri 30 m çözünürlüklü modelden türetilmiştir; arazide yön bulma amaçlıdır,
  ölçme/harita mühendisliği doğruluğunda değildir.

## Biçem

Avcı odaklı, sade topoğrafik:

* Kara krem (`#f3f0e7`), deniz/göl `#a9cfe6`; orman `#aed192`, çalılık, çayır, tarla, bahçe/meyvelik,
  sulak alan (mavi tarama), kum/plaj, çıplak alan, yerleşim, sanayi, mezarlık, park.
* **Askeri alanlar** kırmızı tarama + kesik çizgi (girilmez).
* Tepe gölgesi (KB ışık, yakınlığa göre düşey abartma) arazi örtüsünün üstüne çarpma/ışıltı karışımıyla.
* Eş yükselti: z10–11 100 m, z12 50 m (100 m kalın), z13–15 20 m, 100 m ana eğri kalın ve etiketli.
* Yollar sınıfa göre: otoyol (kırmızı), devlet yolu (turuncu), birincil (sarı-turuncu), ikincil (sarı),
  üçüncül/köy yolu (beyaz, gri kılıf), servis yolu (z14+). **Tarla/orman yolu** (`highway=track`)
  kahverengi kesik çizgi z12+, **patika** (path/footway/bridleway) kırmızı noktalı z13+. Tüneller soluk kesik.
* Demiryolu (z13+ klasik siyah-beyaz), enerji hatları (z13+), yarlar (z13+), dereler/nehirler,
  su kaynakları (`natural=spring`, z14+ mavi nokta), yapılar (z14+).
* İl dışı soluk beyaz örtüyle bastırılır; il sınırı karadaki kısmında mor kesik çizgi.
* Yazılar: şehir/ilçe/köy/mahalle/mevki adları (Türkçe, beyaz haleli), zirveler ▲ ad + yükselti,
  büyük göl/baraj adları. Yer adları tüm il için tek seferde çakışmasız yerleştirildiğinden karo
  kenarında kesilmez; eğri yükseltileri yalnız kendi metakarosunun içine yazılır.

Kodlama: en çok 256 renkli karolar kayıpsız paletli PNG (renk azaltma yapılmaz), diğerleri
JPEG (kalite 78, 4:2:0). Metakaro 8×8 karo + 64 px pay olarak çizilip kesilir; `multiprocessing`
ile tüm çekirdekler kullanılır.

## Boyutlar

Son başarılı çalıştırmanın değerleri iş akışı özetinde (`$GITHUB_STEP_SUMMARY`) ve Release'teki
`basemap_manifest.json` içindedir. Sınırlar iş akışında denetlenir (düşük ≤ 15 MB, yüksek ≤ 150 MB);
aşılırsa yükleme yapılmaz — `jpeg_quality` girdisini düşürüp elle çalıştırın.

## Yeniden üretme

GitHub'da: **Actions › Çevrimdışı altlık harita › Run workflow** (ya da `tools/render_basemap.py`
veya iş akışı değişip push edildiğinde kendiliğinden). İş Geofabrik özetini (haftalık önbellek),
DEM ve WorldCover karolarını (kalıcı önbellek) indirir, tüm ili çizer, yapıt olarak yükler ve
`basemap-istanbul` Release'inin dosyalarını (`--clobber`) günceller.

Yerelde:

```sh
sudo apt-get install osmium-tool libcairo2-dev pkg-config fonts-dejavu-core
python3 -m venv .venv && .venv/bin/pip install numpy scipy shapely pycairo pillow rasterio scikit-image
curl -fLo veri/turkey-latest.osm.pbf https://download.geofabrik.de/europe/turkey-latest.osm.pbf
.venv/bin/python tools/render_basemap.py --osm veri/turkey-latest.osm.pbf --cache veri/basemap \
    --out cikti --samples cikti/ornekler
```

Küçük deneme (Şile/Ağva; il sınırı aranmaz):

```sh
curl -o agva.osm "https://api.openstreetmap.org/api/0.6/map?bbox=29.75,41.08,29.95,41.20"
.venv/bin/python tools/render_basemap.py --osm agva.osm --bbox 29.75,41.08,29.95,41.20 \
    --no-province --cache veri/basemap --out deneme --pack deneme:11-15 --samples deneme/ornekler
```

`--samples` her yakınlık için bir mozaik, birkaç tekil karo ve `kontak_tabakasi.png` yazar.
Tam il çalıştırması 4 çekirdekli GitHub koşucusunda yaklaşık bir saat sürer.
