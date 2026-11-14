# Devam noktası — oturumlar arası durum

Sahibi "devam" deyince yeni oturum bu dosyayı okur ve **"Sıradaki iş"ten** sürdürür. Her işin yanındaki
[model] etiketi o işin (ya da alt ajanının) önerilen modelidir; kural CLAUDE.md › Model seçimi ve alt ajanlar. Bir iş bitince ya da yön
değişince bu dosya güncellenir (aynı PR'da). Tamamlanan işler kısa tutulur; ayrıntı PR'larda ve CHANGELOG'da.

## Son durum (2026-11-14)

- `main` temiz, açık PR yok. Son birleşenler: #57 cam araç sütunu, #58 av defterine tüfek + fişek notu ve tüfek
  ekran görüntüsü düzeltmesi, #59 README güncellemesi, #60 CLAUDE.md model seçimi kuralı.
- Tüfek, şok ve saçma öneri planı **tamamlandı** (`docs/plan/TUFEK_ONERI_PLANI.md`); ekran görüntüleri
  (`appstore-ekran.yml`, kume=tufek) `main` üzerinde yeniden çekildi ve doğrulandı.
- Model ince ayarı **bırakıldı** (CLAUDE.md › Ürün kararları): kuş bulucu ve fotoğraf modeli yeniden eğitilmez.
- Sürüm hâlâ **v0.9.1**; CHANGELOG "Yayımlanmamış" bölümünde tüfek özellikleri, araç sütunu ve av defteri notu birikti.

## Sıradaki iş: gerçek iPhone'da çalıştırma (sahibinin Mac'i ile)

Sahibinin Mac'i ve Xcode 26'sı var. Amaç: uygulamayı iPhone'a yüklemek, ardından `docs/saha_test_protokolu.md`.

**Mac'i bulut oturumuna bağlama denendi:** `list_computer_folders` boş döndü (Remote Control'de paylaşılmış klasör
yok). Sahibine iki yol anlatıldı: (A) Mac'te `git clone https://github.com/oguzbay-del/Av ~/Developer/Av`, Claude
masaüstü uygulaması › Settings › Claude Code › Remote Control'den klasörü eklemek (özellik her hesapta açık değil);
(B) Mac'te aynı klasörde yerel Claude Code oturumu açmak (kesin çalışır). Sahibi hangisini yaptığını söyleyince
devam edilir; A ise klasörler yeniden listelenip `request_computer_folder` ile bağlanılır.

**Sahibinden yanıt bekleyen iki karar:**

1. **Bundle ID.** [Opus: pbxproj/CI; varsayılan kimlik taraması Haiku alt ajanı] Projede yer tutucu `com.example.avharitasi` var: `project.pbxproj`'de 12 yerde (5 hedef;
   `AV_APP_BUNDLE_ID` iki yapılandırmada, `APP_GROUP_ID = group.$(AV_APP_BUNDLE_ID).paylasim`, watch
   `WKCompanionAppBundleIdentifier` zaten değişkenden). Plan: tüm hedeflerin `PRODUCT_BUNDLE_IDENTIFIER`'ını
   `$(AV_APP_BUNDLE_ID)` + sonek (`.widget`, `.watchkitapp`, `.watchkitapp.complication`, `.tests`) yapan tek PR;
   kalıcı kimlik sahibinin seçtiği değer (öneri `com.oguzbayrakdar.avharitasi`; App Store'da da kullanılır).
   pbxproj değiştiği için CI (ios-build) yeşil beklenir. Varsayılan kimlik ayrıca şuralarda geçiyor ve aynı PR'da
   güncellenir: `fastlane/Fastfile` (2 yer), `fastlane/Appfile`, `.github/workflows/testflight.yml`
   (`vars.APP_IDENTIFIER` yoksa varsayılan), `docs/YAYIN.md` tablosu.
2. **Ücretsiz mi ücretli Developer hesabı?** [Opus; adım adım anlatım metni Sonnet alt ajanı] Uygulama App Group (widget/Watch paylaşımı) ve Time Sensitive bildirim
   yeteneklerini kullanıyor; ücretsiz Apple ID ile imzalama hata verebilir. Ücretsizse test için bu yeteneklerin
   Xcode'da nasıl kaldırılacağı (ve neyin çalışmayacağı: widget/Watch veri paylaşımı, Odak'ı delen bildirim)
   adım adım anlatılacak; asıl yasak alan uyarısı testi için ücretli üyelik önerilir.

**Sahibine verilen kurulum adımları:** Xcode › Settings › Accounts'a Apple ID; iPhone'da Geliştirici Modu; dört
hedefte (AvHaritasi, AvDurumWidget, AvSaat, AvSaatKomplikasyon) Signing & Capabilities › Team; şema AvHaritasi,
hedef iPhone, ▶︎; iPhone'da Ayarlar › Genel › VPN ve Aygıt Yönetimi'nden güven; konum izni "Her Zaman".

## Ondan sonra (öneri sırası)

- [Opus] Saha testi (`docs/saha_test_protokolu.md`): önce simülatörde `ios/TestData/GPX/` senaryoları, sonra sahada.
  Bulunan sorunlar düzeltilir.
- [Sonnet] Apple Developer üyeliği, App ID yetenekleri, TestFlight sırları (`ASC_*`; sahibi ekler, adımlar `docs/YAYIN.md`).
- [Sonnet] Gizlilik metnindeki `[Geliştirici adı / e-posta]` yer tutucusu (sahibinden bilgi gerekir).
- [Sonnet; `MARKETING_VERSION` yerleri Haiku taraması] Yayımlanmamış değişiklikler için sürüm etiketi (ör. v0.9.2; `MARKETING_VERSION` 10 yerde + CHANGELOG başlığı).
- [Sonnet] README önizleme görseli (`screenshots/onizleme_tr.jpg`) araç sütunundan önce; yeniden üretilebilir.

## Oturum notları

- Bulut oturumunda repo tek dallı (shallow) klonlanıyor: yeni dal itilince Stop hook "uzak dal yok" diyebilir.
  Çözüm: `git config --add remote.origin.fetch '+refs/heads/<dal>:refs/remotes/origin/<dal>'`, `git fetch`,
  `git branch -u origin/<dal>`.
- GitHub GraphQL bu oturumlarda kapalı: `gh pr list` yerine `gh api repos/oguzbay-del/av/pulls`; birleştirme
  `gh api -X PUT repos/oguzbay-del/av/pulls/<n>/merge -f sha=<40 karakter>`.
