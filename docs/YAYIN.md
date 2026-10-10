# Yayın rehberi (TestFlight ve App Store)

Bu belge, Av Haritası'nın GitHub Actions üzerinden otomatik olarak TestFlight'a yüklenmesini ve App Store'a
gönderilmeden önce yapılması gerekenleri anlatır.

İlgili dosyalar:

| Dosya | Görevi |
|---|---|
| `.github/workflows/testflight.yml` | `v*` etiketi gönderilince (ya da elle) derleyip TestFlight'a yükler |
| `fastlane/Fastfile` | `beta` lane'i: API anahtarı, imzalama, derleme, yükleme |
| `fastlane/Appfile` | Bundle ID ve ekip kimliği (ortam değişkenlerinden) |
| `fastlane/metadata/tr/release_notes.txt` | TestFlight "Neyi test etmeli?" / sürüm notları (TR) |
| `fastlane/metadata/en-US/release_notes.txt` | Sürüm notları (EN) |
| `fastlane/metadata/{tr,en-US}/*.txt` | App Store sayfa metinleri (ad, alt başlık, açıklama, anahtar kelimeler, URL'ler; `deliver` düzeni) |
| `fastlane/metadata/review_information/notes.txt` | App Review notları (arka plan konumu, demo modu) |
| `docs/GIZLILIK.md`, `docs/PRIVACY.md` | Gizlilik politikası (App Store'daki gizlilik URL'si) |
| `.github/workflows/appstore-ekran.yml` | 6.9" App Store ekran görüntüleri (TR/EN, ham + başlıklı): `tools/appstore_screenshots.sh`, `tools/frame_screenshots.py`, metinler `tools/appstore_copy.json` |
| `ios/AvHaritasi.xcodeproj/xcshareddata/xcschemes/AvHaritasi.xcscheme` | Paylaşılan şema (fastlane ve CI için gerekli) |
| `Gemfile` | fastlane sürümü |

Secret'lar tanımlanmadığı sürece iş **başarıyla biter ve yükleme atlanır**; Actions özetinde hangi secret'ların
eksik olduğunu söyleyen bir not görünür. Yani bu kurulum yapılmadan da depoya zarar vermez.

> `project.pbxproj` depoda hiç değiştirilmez. Bundle ID ve imzalama ayarları derleme sırasında geçici olarak
> yazılır, iş bitince eski hâline döndürülür. Sürüm ve derleme numarası `xcodebuild`'e parametre olarak verilir.

---

## 1. Ön koşullar

1. **Apple Developer Program** üyeliği (yıllık ücretli). Ücretsiz Apple ID ile TestFlight kullanılamaz.
2. Ekip kimliğiniz (**Team ID**, 10 karakter): <https://developer.apple.com/account> › *Membership details*.
3. Benzersiz bir **Bundle ID** seçin, ör. `com.adiniz.avharitasi`. Uygulama dört hedeften oluşur:

   | Hedef | Bundle ID | Ne |
   |---|---|---|
   | `AvHaritasi` | `com.adiniz.avharitasi` | iPhone uygulaması (Siri kısayolları dahil) |
   | `AvDurumWidget` | `com.adiniz.avharitasi.widget` | Live Activity, ana ekran ve kilit ekranı aracı |
   | `AvSaat` | `com.adiniz.avharitasi.watchkitapp` | Apple Watch uygulaması |
   | `AvSaatKomplikasyon` | `com.adiniz.avharitasi.watchkitapp.complication` | Saat yüzü komplikasyonu |

   - <https://developer.apple.com/account/resources/identifiers> › **+** › *App IDs* › *App* ile dördünü de
     oluşturun.
   - **App Group**: *Identifiers* › **+** › *App Groups* ile `group.com.adiniz.avharitasi.paylasim` oluşturun;
     sonra dört App ID'nin her birinde *App Groups* capability'sini açıp bu grubu seçin. Uygulama son av
     durumunu buraya yazar; araçlar, Siri kısayolları ve (saatte) komplikasyon buradan okur. Grup adı
     derleme ayarı `APP_GROUP_ID`'dir (`ios/*.entitlements` ve Info.plist'teki `AvAppGroup` bunu kullanır);
     fastlane bunu `group.<APP_IDENTIFIER>.paylasim` olarak verir, farklıysa `APP_GROUP_ID` değişkenini tanımlayın.
   - Uygulamanın App ID'sinde ayrıca **Time Sensitive Notifications** capability'sini açın
     (`ios/AvHaritasi/AvHaritasi.entitlements`: yasak alan uyarıları Odak modunu aşabilsin).
   - Başka capability gerekmez (Live Activity, arka plan konumu ve App Intents için ayrı bir yetki yok).
4. **App Store Connect**'te uygulama kaydı: <https://appstoreconnect.apple.com> › *Uygulamalar* › **+** ›
   *Yeni Uygulama*. Platform iOS, birincil dil Türkçe, Bundle ID yukarıdaki, SKU ör. `avharitasi`.

## 2. App Store Connect API anahtarı

fastlane, Apple ID ve parola yerine bu anahtarla giriş yapar (iki adımlı doğrulama sorunu olmaz).

1. App Store Connect › *Kullanıcılar ve Erişim* › **Entegrasyonlar** › *App Store Connect API* ›
   *Ekip Anahtarları* › **+**.
2. Ad: `GitHub Actions`. Erişim:
   - **match** ile imzalama kullanacaksanız **App Manager** yeterli.
   - **Otomatik imzalama** kullanacaksanız **Admin** gerekir (Xcode'un profil oluşturabilmesi için).
3. **API Anahtarını İndir** ile `AuthKey_XXXXXXXXXX.p8` dosyasını indirin. *Bu dosya yalnızca bir kez
   indirilebilir*; güvenli bir yerde saklayın.
4. Sayfada görünen **Issuer ID** (UUID) ve **Key ID** (10 karakter) değerlerini not edin.
5. Dosyayı base64'e çevirin (secret'a bu yazılacak):

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy   # macOS: panoya kopyalar
   # Linux: base64 -w0 AuthKey_XXXXXXXXXX.p8
   ```

## 3. İmzalama: match (önerilen) ya da otomatik

### Seçenek A — fastlane match

Sertifika ve profiller şifreli olarak ayrı, **özel** bir Git deposunda tutulur. CI yalnızca okur.

1. GitHub'da boş, **private** bir depo açın, ör. `adiniz/ios-sertifikalar`.
2. Bir Mac'te bu depoda (Av klasöründe) bir kez çalıştırın:

   ```bash
   bundle install
   export APP_IDENTIFIER=com.adiniz.avharitasi TEAM_ID=AB12CD34EF
   bundle exec fastlane match init          # "git" seçin, depo adresini girin
   bundle exec fastlane match appstore \
     --app_identifier "com.adiniz.avharitasi,com.adiniz.avharitasi.widget,com.adiniz.avharitasi.watchkitapp,com.adiniz.avharitasi.watchkitapp.complication" \
     --team_id "$TEAM_ID"
   ```

   Sizden bir **parola** (MATCH_PASSWORD) ister; depodaki dosyalar bununla şifrelenir. Not edin.
   Profiller App Group'u içermelidir: grubu App ID'lere profilleri oluşturduktan *sonra* eklediyseniz
   aynı komutu `--force` ile yeniden çalıştırın (eski profiller App Group yetkisini taşımaz, imzalama
   "Provisioning profile doesn't include the com.apple.security.application-groups entitlement" ile durur).
   `match init` bir `fastlane/Matchfile` oluşturur; isterseniz commit edebilirsiniz (gizli bilgi içermez).
3. CI'ın özel depoyu okuyabilmesi için yalnızca o depoya *Contents: Read* izni olan bir
   **fine-grained personal access token** oluşturun ve şunu hesaplayın:

   ```bash
   echo -n "github-kullanici-adiniz:github_pat_XXXX" | base64
   ```

   Sonuç `MATCH_GIT_BASIC_AUTHORIZATION` secret'ı olur. `MATCH_GIT_URL` için HTTPS adresini kullanın
   (`https://github.com/adiniz/ios-sertifikalar.git`).

### Seçenek B — Otomatik imzalama

match deposu istemiyorsanız `MATCH_GIT_URL` secret'ını tanımlamayın (ya da `SIGNING_MODE` değişkenini
`automatic` yapın). Xcode, Admin rollü API anahtarıyla dağıtım sertifikası ve profilleri kendisi oluşturur
(`-allowProvisioningUpdates`). Dezavantajı: her CI çalışması yeni bir dağıtım sertifikası oluşturabilir;
Apple ekip başına sınırlı sayıda sertifikaya izin verir, birikenleri arada bir silmeniz gerekebilir.

## 4. GitHub secret'ları ve değişkenleri

Depo › *Settings* › *Secrets and variables* › *Actions*.

**Secrets** (zorunlu):

| Ad | Değer |
|---|---|
| `ASC_KEY_ID` | API anahtarının Key ID'si |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_CONTENT` | `.p8` dosyasının base64 hâli (adım 2.5) |
| `TEAM_ID` | Apple ekip kimliği |

**Secrets** (yalnızca match ile):

| Ad | Değer |
|---|---|
| `MATCH_GIT_URL` | Sertifika deposunun HTTPS adresi |
| `MATCH_PASSWORD` | match şifreleme parolası |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `kullanici:token` dizesinin base64 hâli (adım 3A.3) |

**Variables** (isteğe bağlı, *Variables* sekmesi):

| Ad | Varsayılan | Açıklama |
|---|---|---|
| `APP_IDENTIFIER` | `com.example.avharitasi` | Uygulamanın Bundle ID'si — **mutlaka kendi kimliğinizi yazın** |
| `WIDGET_IDENTIFIER` | `<APP_IDENTIFIER>.widget` | Eklentinin Bundle ID'si |
| `WATCH_IDENTIFIER` | `<APP_IDENTIFIER>.watchkitapp` | Apple Watch uygulamasının Bundle ID'si |
| `COMPLICATION_IDENTIFIER` | `<WATCH_IDENTIFIER>.complication` | Saat komplikasyonunun Bundle ID'si |
| `APP_GROUP_ID` | `group.<APP_IDENTIFIER>.paylasim` | Dört hedefin paylaştığı App Group |
| `SIGNING_MODE` | `MATCH_GIT_URL` varsa `match`, yoksa `automatic` | İmzalama yöntemi |
| `WAIT_FOR_PROCESSING` | `false` | `true` ise Apple'ın derlemeyi işlemesi beklenir ve sürüm notları TestFlight'a yazılır (iş 10-30 dk uzar) |

## 5. Sürüm yayınlama (etiket)

1. `fastlane/metadata/tr/release_notes.txt` ve `en-US/release_notes.txt` dosyalarını güncelleyin;
   `docs/CHANGELOG.md`'ye yeni bir başlık ekleyin. Commit edip `main`'e gönderin.
2. Etiketleyin:

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. *Actions* › **TestFlight** işini izleyin. Sürüm etiketten türetilir (`v1.2.3` → `1.2.3`), derleme
   numarası iş sayacıdır (`github.run_number`), dolayısıyla her yükleme benzersizdir. Elle tetiklenen
   (*Run workflow*) çalışmalar `1.0` sürümüyle yüklenir.
4. Yükleme bitince derleme 10-30 dk içinde App Store Connect › *TestFlight* sekmesinde görünür. İlk derlemede
   **Export Compliance** (şifreleme) sorusu sorulur: uygulama yalnızca HTTPS kullandığı için "standart
   şifreleme / muaf" seçeneği uygundur. Kalıcı çözüm için Info.plist'e
   `ITSAppUsesNonExemptEncryption = NO` eklenebilir.
5. **İç test**: TestFlight › *Dahili Test* grubuna ekip üyelerini ekleyin (inceleme gerekmez).
   **Dış test**: *Harici Test* grubu oluşturun; ilk derleme kısa bir Beta App Review'dan geçer.

### Kademeli yayın ve sürüm notları

- App Store'a gönderirken sürüm sayfasında **"Kademeli Yayın"** (Phased Release) seçeneğini açın: güncelleme
  otomatik güncellemesi açık kullanıcılara 7 gün içinde %1 → %2 → %5 → %10 → %20 → %50 → %100 oranında
  ulaşır. Bir sorun görülürse yayını 30 güne kadar duraklatabilirsiniz; App Store'dan elle indiren herkes
  yeni sürümü hemen alır. İlk sürümde (1.0) kademeli yayın uygulanmaz.
- "Bu sürümdeki yenilikler" metni her dil için ayrı girilir; `fastlane/metadata/<dil>/release_notes.txt`
  dosyalarındaki metni kopyalayın (en fazla 4.000 karakter). Kısa, avcıya yönelik maddeler yazın; sezon
  verisi güncellemelerini (yeni MAK kararı, yeni harita) mutlaka belirtin.
- Sezon başında (MAK kararı yenilendiğinde) veri güncellemesini kademeli değil, **hemen** yayınlamak daha
  doğrudur; eski kurallarla avcıyı yanıltmamak için.

## 6. App Store'a göndermeden önce kontrol listesi

- [ ] **Gizlilik bildirimi (Privacy Manifest):** `ios/AvHaritasi/PrivacyInfo.xcprivacy` güncel mi? Kullanılan
      "required reason" API'leri (ör. `UserDefaults`, dosya zaman damgası) ve toplanan veri türleri
      (yaklaşık konum → hava tahmini/kuş sesi sunucusu) doğru beyan edilmiş mi? Eklentide de gerekiyorsa ekleyin.
- [ ] **Gizlilik politikası URL'si:** App Store Connect › *Uygulama Gizliliği* bölümüne erişilebilir bir sayfa
      adresi girin (GitHub Pages yeterli). Konumun cihazda işlendiği, konum geçmişinin saklanmadığı, izin
      belgesindeki ad/numaraların kaydedilmediği, Open-Meteo'ya ve (isteğe bağlı) BirdNET sunucusuna yaklaşık
      konum/ses gönderildiği açıkça yazılmalı.
- [ ] **Uygulama Gizliliği etiketleri** ("nutrition label") gizlilik bildirimiyle uyumlu.
- [ ] **İnceleme notları — arka plan konumu:** Apple, `UIBackgroundModes: location` ve "Her Zaman" konum
      iznini sıkı inceler. *App Review Information › Notes* alanına örneğin şunu yazın:
      > Uygulama, avcıların Türkiye'deki ava yasak alanlara (Tarım ve Orman Bakanlığı MAK kararı) girmesini
      > önlemek için uyarı verir. "Her Zaman" konum izni ve arka plan konumu yalnızca kullanıcı Ayarlar'dan
      > "Arka planda takip"i açarsa istenir; telefon cepteyken yasak alana ~100 m kala bildirim göndermek için
      > kullanılır (CLMonitor). Konum geçmişi saklanmaz ve sunucuya gönderilmez. Test için: haritada İstanbul,
      > Sarıkavak Devlet Avlağı çevresine konum simülasyonu yapın.
      Gerekirse arka plan uyarısını gösteren kısa bir ekran kaydı videosu bağlantısı ekleyin.
- [ ] **İzin metinleri** (`NSLocation…UsageDescription`) Türkçe ve İngilizce, amacı açıkça anlatıyor.
- [ ] **Ekran görüntüleri:** en az 6,9" (iPhone 16/17 Pro Max, 1320×2868) boyutu; TR ve EN için ayrı.
      *Ekran görüntüleri* iş akışı (`.github/workflows/ekran-goruntuleri.yml`) ham görüntüleri üretir.
- [ ] **Uygulama açıklaması** "resmi değildir; yasal sorumluluk avcıya aittir" uyarısını içeriyor. Bakanlık
      logosu veya resmi kurum izlenimi veren ad/görsel kullanılmıyor (Yönerge 5.2 / 4.1).
- [ ] **Yaş derecelendirmesi:** av/silah teması nedeniyle anket dikkatle doldurulmalı (gerçekçi şiddet yok).
- [ ] **Lisanslar:** BirdNET ve Xeno-canto kayıtları CC BY-NC-SA 4.0 — **ücretsiz** ve reklamsız dağıtım
      gerekir; künyeler uygulamada (Ayarlar › Kuş sesleri) görünüyor. OpenStreetMap/OpenTopoMap atıfları
      haritada görünüyor.
- [ ] **Destek URL'si** ve iletişim e-postası.
- [ ] **Export Compliance** yanıtlandı (adım 5.4).
- [ ] Gerçek bir iPhone'da TestFlight derlemesiyle: arka plan uyarısı, bildirimler, Live Activity, Apple Watch
      Akıllı Yığın ve çevrimdışı harita denendi.

## 7. Kod stili (SwiftLint)

`.swiftlint.yml` mevcut koda göre gevşetilmiş kuralları içerir; `.github/workflows/lint.yml` her `ios/**`
değişikliğinde çalışır ve uyarıları PR'da satır üzerinde gösterir. Şimdilik **engelleyici değildir**
(`continue-on-error: true`). Mevcut uyarılar temizlendikten sonra bu satır kaldırılacak ve lint zorunlu
hâle gelecek. Yerelde: `brew install swiftlint && swiftlint lint`.

## Dağıtım: yalnızca Türkiye

Harita ve kurallar yalnızca İstanbul (Türkiye) için geçerlidir; uygulama başka ülkede yanıltıcı olur.

1. App Store Connect › Uygulama › **Fiyatlandırma ve Erişilebilirlik** (Pricing and Availability)
2. **Ülke veya bölge erişilebilirliği** › Düzenle › "Tümü" seçimini kaldırın, yalnızca **Türkiye**'yi işaretleyin › Kaydet
3. "Yeni ülkeler ve bölgeler otomatik eklensin" seçeneğini kapatın.
4. TestFlight harici test için aynı kısıt geçerli değildir; test kullanıcılarını elle ekleyin.

İnceleme notlarında (App Review Information › Notes) belirtin:

> The app is distributed in Türkiye only; its map and rules cover Istanbul hunting zones.
> Outside Türkiye, use **Settings (Ayarlar) › Advanced (Gelişmiş) › Demo mode (for App Review)** or launch with
> the argument `-demoKonum`: a simulated walk at Sarıkavak, Istanbul enters a no-hunting area;
> a yellow warning appears after ~25 s and a red "do not hunt" alert after ~40 s.
> The app works without an account. Privacy policy: https://github.com/oguzbay-del/Av/blob/main/docs/PRIVACY.md

## Gizlilik politikası

- Türkçe: https://github.com/oguzbay-del/Av/blob/main/docs/GIZLILIK.md
- İngilizce: https://github.com/oguzbay-del/Av/blob/main/docs/PRIVACY.md
- App Store Connect › Uygulama Gizliliği › Gizlilik Politikası URL'si alanına İngilizce bağlantıyı girin.
- Yayından önce metindeki "[Geliştirici adı / e-posta]" yer tutucusunu doldurun.
