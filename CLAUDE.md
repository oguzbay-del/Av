# Av Haritası — Claude için proje notları

İstanbul'da avcılar için iOS uygulaması: yasak/avlanabilir alan haritası ve uyarıları, MAK 2026-27 kuralları,
av günü/saati, rüzgâr, işaretler, kuş sesi ve fotoğrafından tür tanıma. Sahibiyle Türkçe konuşulur.

## Ürün kararları (değiştirmeden önce sor)

- **Yalnızca İstanbul.** Bölge ekleme özelliği yok, eklenmeyecek.
- **Çevrimdışı öncelikli.** Her şey internetsiz çalışır. Tek istisnalar: hava durumu (Open-Meteo), belirsiz kuş
  tanımada isteğe bağlı çevrimiçi kontrol (Google Cloud Run, Ayarlar'dan kapatılır), anonim kullanım istatistiği
  (TelemetryDeck, Ayarlar'dan kapatılır, kimlik/tam konum/yasak alan bilgisi asla gönderilmez).
- Güvenlik uyarıları (yasak alan, bayat GPS) hiçbir koşulda susturulmaz; Face ID kilidi bile konumu/uyarıyı durdurmaz.
- Merlin bağlantısı kaldırıldı; geri eklenmez. Kendi ses modelimizi eğitmiyoruz (BirdNET yeterli).
- Uygulama şimdilik ücretsiz. BirdNET (CC BY-NC-SA) ve fotoğraf modeli (CC BY-NC fotoğraflar) ticari olmayan
  kullanım içindir; ücretli sürüm düşünülürse önce lisans çözülmeli.

## Depo düzeni

- `ios/` — Xcode projesi (elle yazılmış `project.pbxproj`, PBXFileSystemSynchronizedRootGroup: mevcut klasörlere
  eklenen dosyalar otomatik dahil olur; **Swift paketi eklenmez**). Hedefler: AvHaritasi, AvDurumWidget,
  AvSaat (watch), AvSaatKomplikasyon, AvHaritasiTests. Ortak kod `ios/Shared`.
- `ios/AvHaritasi/BirdNET/` — BirdNET V2.4 Core ML, 333 İstanbul türüne indirgenmiş; tür listesi
  `BirdNET_Istanbul_Weeks.json` (fotoğraf modeli ve sunucu da bu listeyi kullanır).
- `ios/AvHaritasi/BirdPhoto/` — fotoğraftan tanıma (`BirdClassifier.mlpackage`, 331 tür, test %81,8;
  ayrıntı `docs/KUS_FOTO_MODELI.md`). `IstanbulSpecies` etiketleri MAK adına ve Türkçe ada çevirir.
- `tools/kus_foto/` — fotoğraf modeli eğitimi (Kaggle/Colab, `kus_foto.py` adımları: indir, egit,
  degerlendir, performans, aktar). `tools/kus_sunucu/` — Cloud Run sunucusu (BioCLIP 2 + Perch v2).
- `tools/l10n.py` + `tools/l10n/en.json` — çeviri. `docs/` — yayın, gizlilik, test planı, MAK okuması.
- `harita-veri` (ayrı public depo) — çevrimdışı harita paketleri ve yayımlanan gizlilik metinleri.

## Kurallar

- Kod yorumları ve UI kaynak metinleri **Türkçe**; metinler `L()` / `LD()` ile. Yeni metin → `tools/l10n/en.json`'a
  İngilizcesi, sonra `python3 tools/l10n.py` ve `python3 tools/l10n.py --check` **0 eksik / 0 kullanılmayan**.
  `en.json` çakışmasında iki tarafı birleştir, xcstrings'i araçla yeniden üret.
- Saf karar mantığı (AlertPolicy, PowerModePolicy, OnlineCheckPolicy…) ayrı ve birim testli tutulur.
- Burada macOS yok: derleme ve testler CI'da (`ios-build.yml`, Xcode 26) ve `lint.yml` (SwiftLint) koşar;
  `claude/**` dallarına her push'ta çalışırlar.
- Gizlilik etkisi olan her değişiklikte `docs/GIZLILIK.md`, `docs/PRIVACY.md`, `docs/YAYIN.md` (App Store gizlilik
  formu) ve gerekirse `PrivacyInfo.xcprivacy` güncellenir.

## Komutlar (CI'dakilerle aynı; derleme/test yalnızca macOS + Xcode 26'da)

```sh
# Çeviri (her yerde): katalogları üret ve denetle — CI güncel olmayan kataloğu reddeder
python3 tools/l10n.py && python3 tools/l10n.py --check

# Simülatör için derle
xcodebuild build -project ios/AvHaritasi.xcodeproj -scheme AvHaritasi -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath ios/build/DerivedData CODE_SIGNING_ALLOWED=NO

# Birim testleri (Türkçe yerel ayar; "iPhone 17 Pro" yerine kurulu herhangi bir iPhone simülatörü)
xcodebuild test -project ios/AvHaritasi.xcodeproj -scheme AvHaritasi -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" -derivedDataPath ios/build/DerivedData \
  -testLanguage tr -testRegion TR CODE_SIGNING_ALLOWED=NO

# Lint (kurallar .swiftlint.yml)
swiftlint lint
```

Bulut oturumlarında macOS olmadığından derleme ve testler GitHub Actions'ta doğrulanır (`ios-build.yml`, `lint.yml`).

## Çalışma düzeni

- Sahibi bağımsız işlerde paralel ajan kullanılmasını ve **CI yeşil olunca beklemeden PR birleştirilmesini** ister.
  Swift'e dokunmayan (yalnızca araç/belge) PR'lar CI beklemeden birleştirilebilir.
- PR'lar dal → `main`; birleştirmede tam 40 karakterlik head SHA verilir. Birleşmiş dalın üstüne yeni iş eklenmez.
- Gizli değerler (token, anahtar) asla depoya, PR'a ya da mesaja yazılmaz; GitHub sırları/değişkenleri kullanılır.
- Token tasarrufu istendiğinde kısa yanıt ver; "dur" denince işleri durdur, "devam" denince sürdür.

## Altyapı

- CI iş akışları `.github/workflows/`: ios-build, lint, testflight, appstore-ekran, ekran-goruntuleri,
  offline-harita, osm-veri, veri-deposu-esitle (`HARITA_VERI_TOKEN`), kus-sunucu (Cloud Run, Workload Identity
  Federation; değişkenler `GCP_PROJECT`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`), kus-foto-dogrula (Core ML'i macOS'ta
  PyTorch ile karşılaştırır).
- Çevrimiçi tanıma sunucusu: `https://kus-sunucu-dvvcqnbeyq-ew.a.run.app` (`/saglik`, `/foto`, `/ses`),
  europe-west1, en çok 2 kopya, kullanılmayınca kapanır. Uygulamadaki adres `OnlineBirdID.baseURL`.
- Kullanım istatistiği: `UsageStats.appID` (TelemetryDeck, SDK'sız istemci).

## Bekleyen (sahibinde)

Apple Developer üyeliği ve App ID yetenekleri (App Group, Time Sensitive), TestFlight sırları (ASC_*), gizlilik
metnindeki "[Geliştirici adı / e-posta]", gerçek cihaz testi (`docs/saha_test_protokolu.md`).
