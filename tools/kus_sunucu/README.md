# Av Haritası — çevrim içi yedek kuş tanıma sunucusu

Av Haritası iOS uygulaması kuşları önce cihaz üzerinde tanır. Cihazdaki model
emin olmadığında fotoğraf ya da ses kaydı bu sunucuya gönderilir; sonuçlar
İstanbul'da görülen **333 türle** sınırlıdır. Sunucu Google Cloud Run'da
(`europe-west1`, Belçika) çalışır; kullanılmadığında sıfır örneğe iner.

| Uç nokta | Girdi | Model |
|---|---|---|
| `POST /foto` | multipart `file`, görüntü ≤ 10 MB | BioCLIP 2 sıfır-atış |
| `POST /ses` | multipart `file`, ses ≤ 10 MB ve ≤ 30 sn | Perch v2 (5 sn pencere, 32 kHz) |
| `POST /geribildirim` | JSON, ≤ ~2 MB (aşağıya bakın) | — (özel GitHub deposunda konu açar) |
| `GET /saglik` | — | durum, tür sayısı, Perch eşleşen tür sayısı, `geribildirim` (açık mı) |

Yanıt: `{"model": "...", "sonuclar": [{"sci","en","tr","p"}], "sure_ms": 123}`
(`/ses` ayrıca `pencere` sayısını döndürür). Hatalar `{"hata": "..."}` biçimindedir.
IP başına 10 dakikada 30 istek sınırı vardır.

```sh
curl -F file=@saksagan.jpg https://kus-sunucu-XXXXXXXXXX.europe-west1.run.app/foto
```

Gerçek adres dağıtımdan sonra Actions özetinde ve `gcloud run services describe
kus-sunucu --region europe-west1 --format='value(status.url)'` çıktısında görünür.

## Kurulum (bir kez, telefondan yapılabilir)

1. **Google Cloud hesabı ve faturalandırma:** https://console.cloud.google.com
   adresinde Google hesabınızla oturum açın, koşulları kabul edin ve
   *Faturalandırma* bölümünde bir fatura hesabı (kart) ekleyin. Ücretsiz kullanım
   kotası için de kart gerekir. Kişisel (gmail) hesap kullanın: şirket
   kuruluşlarındaki projelerde hizmeti herkese açmak (`allUsers`) ilkeyle
   engellenmiş olabilir.
2. **Proje:** üst çubuktaki proje seçiciden *Yeni proje* → ad örn. `av-haritasi`.
   Projenin faturalandırma hesabına bağlı olduğundan emin olun.
3. **Cloud Shell:** https://shell.cloud.google.com açın. Proje seçili değilse:
   ```sh
   gcloud config set project PROJE_KIMLIGI
   ```
4. **Kurulum betiği:** Cloud Shell'e yapıştırın:
   ```sh
   bash <(curl -fsSL https://raw.githubusercontent.com/oguzbay-del/Av/main/tools/kus_sunucu/gcp_kurulum.sh)
   ```
   İsteğe bağlı 5 USD aylık bütçe uyarısı için sonuna
   `--butce FATURA_HESABI_KIMLIGI` ekleyin (kimlik: `gcloud billing accounts list`).
   Betik tekrar çalıştırılabilir; anahtar dosyası oluşturmaz.
5. **GitHub değişkenleri:** betiğin sonunda yazdırdığı üç değeri
   https://github.com/oguzbay-del/Av/settings/variables/actions →
   *New repository variable* ile ekleyin (**Variables** sekmesi, Secrets değil):
   `GCP_PROJECT`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`.
6. **Dağıtım:** GitHub → *Actions* → **Kuş sunucusu (Cloud Run)** → *Run workflow*.
   İlk derleme ~15–25 dk sürer; sonunda hizmet adresi yazdırılır ve `/saglik`
   denetlenir. Sonra bu adresi uygulamaya girin.

Bundan sonra `main` dalında `tools/kus_sunucu/` altında yapılan her değişiklik
`.github/workflows/kus-sunucu.yml` ile otomatik dağıtılır. Değişkenler yoksa iş
akışı yalnızca bir uyarı bırakıp başarıyla biter.

## Uygulama içi geri bildirim (`POST /geribildirim`)

Uygulamadaki *Ayarlar › Yardım › Geri bildirim gönder* formu buraya gelir; sunucu
geliştiricinin **özel** GitHub deposunda (`GERIBILDIRIM_REPO`, varsayılan
`oguzbay-del/av-geribildirim`) bir konu (issue) açar. Kod: `geribildirim.py`,
testler: `python3 -m pytest tools/kus_sunucu` (CI: kus-sunucu.yml `testler`).

```json
{"tur": "hata|oneri|harita|kus", "metin": "≤ 2000 karakter (zorunlu)",
 "iletisim": "≤ 200 (isteğe bağlı)", "uygulama": "1.4 (52)", "ios": "26.0", "cihaz": "iPhone17,1",
 "konum": {"lat": 41.1234, "lon": 29.1234}, "gorsel": "<base64 JPEG ≤ 1,5 MB>"}
```

- Bilinmeyen alan, yanlış tür, sınır aşımı → `400`; `konum` yalnızca `tur: "harita"` ile kabul edilir.
- `X-Av-Uygulama: 1` başlığı zorunludur (güvenlik değil, yalnızca gürültü süzgeci).
- Hız sınırı (kopya başına, bellekte): IP başına **saatte 5, günde 20** → `429`. IP, süreç başına
  rastgele tuzla karılmış olarak tutulur; IP ve başlıklar hiçbir yere yazılmaz.
- Konu: başlık `[tür] metnin ilk 60 karakteri`, etiketler `geri-bildirim` + tür; metin kod bloğunda
  (bahsetme/bağlantı işlenmez), konum 5 ondalıkla OpenStreetMap bağlantısı, uygulama/iOS/cihaz bilgisi.
  Görsel varsa önce aynı depoya `ekler/<uuid>.jpg` olarak (contents API) yüklenir, konudan bağlanır;
  yüklenemezse konu görselsiz açılır.
- Jeton (`GERIBILDIRIM_GITHUB_TOKEN`) yoksa ya da GitHub yanıt vermezse `503`; uygulama bildirimi
  sırada tutar ve sonra yeniden dener. `/saglik` yanıtındaki `geribildirim` alanı jetonun bağlı olup olmadığını gösterir.

### Kurulum (bir kez)

1. **Özel depo:** GitHub'da *New repository* → `av-geribildirim`, **Private**, "Add a README" işaretli
   (boş depo da çalışır).
2. **Jeton:** GitHub › Settings › Developer settings › *Fine-grained personal access tokens* › *Generate new
   token*: Repository access → **Only select repositories** → `av-geribildirim`; Permissions → Repository →
   **Issues: Read and write**, **Contents: Read and write** (Metadata: Read otomatik). Süre: en çok 1 yıl
   (dolunca 4. adımı yeni sürümle tekrarlayın). Jetonu hiçbir dosyaya, PR'a ya da mesaja yazmayın.
3. **Secret Manager:** Cloud Shell'de (jeton yapıştırılır, Enter, ardından Ctrl+D):
   ```sh
   gcloud services enable secretmanager.googleapis.com
   gcloud secrets create geribildirim-github-token --replication-policy=automatic --data-file=-
   ```
   Jeton yenilenince: `gcloud secrets versions add geribildirim-github-token --data-file=-`
   (Cloud Run `latest` sürümü yeni kopyalarda okur; hemen geçsin isterseniz 6. adımı yineleyin).
4. **Okuma izni** (çalışma hesabı `kus-sunucu`):
   ```sh
   PROJE=$(gcloud config get-value project)
   gcloud secrets add-iam-policy-binding geribildirim-github-token \
     --member="serviceAccount:kus-sunucu@$PROJE.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```
5. **GitHub değişkeni:** https://github.com/oguzbay-del/Av/settings/variables/actions →
   `GERIBILDIRIM_AKTIF` = `true` (Variables sekmesi). Başka depo kullanılacaksa `GERIBILDIRIM_REPO` da ekleyin.
6. **Yeniden dağıt:** Actions › **Kuş sunucusu (Cloud Run)** › *Run workflow*. Sonra
   `curl https://…run.app/saglik` → `"geribildirim": true`.

`GERIBILDIRIM_AKTIF` tanımlı değilken dağıtım jeton bağlamaz (sır yokken Cloud Run dağıtımı reddederdi):
uç `503` döner, kuş tanıma etkilenmez.

## Maliyet

Hizmet istek başına faturalanır (boşta CPU/bellek ücreti yok), en az 0, en çok
2 örnek; 2 vCPU, 8 GiB. Aylık ücretsiz kota (istek başına faturalama,
[Cloud Run fiyatları](https://cloud.google.com/run/pricing)): **180.000 vCPU-saniye,
360.000 GiB-saniye ve 2 milyon istek**. Bir örnek 2 vCPU × 8 GiB kullandığından
kota, ayda yaklaşık 12 saat etkin çalışmaya (bellek sınırı) denk gelir;
ara sıra yapılan tanıma istekleri bunun çok altında kalır.

İmaj deposu ([Artifact Registry fiyatları](https://cloud.google.com/artifact-registry/pricing)):
ilk **0,5 GB ücretsiz**, sonrası GB başına ayda **~0,10 USD**; aynı bölgedeki
Cloud Run'a imaj aktarımı ücretsizdir. Sıkıştırılmış imaj birkaç GB olduğundan ve
temizlik ilkesi yalnızca en yeni 2 sürümü tuttuğundan depolama ayda **birkaç on
sent** (kabaca 0,3–0,6 USD) tutar. Bütçe uyarısı kurduysanız beklenmeyen bir
artışta e-posta gelir.

## Gizlilik

Yüklenen dosyalar yalnızca bellekte işlenir; **hiçbir zaman diske yazılmaz,
saklanmaz ve günlüğe kaydedilmez**. Geri bildirim bunun tek istisnasıdır: kullanıcının
gönderdiği metin, isteğe bağlı e-posta, konum ve görsel özel GitHub deposunda konu olarak
saklanır (IP ve başlıklar yazılmaz). Erişim günlüğü kapalıdır. (Cloud Run kendi
istek günlüğünde yol, durum kodu ve IP gibi üst bilgileri tutar; dosya içeriği
tutulmaz.)

## Teknik notlar

- Modeller Docker derlemesinde indirilip ısındırılır (`python app.py --isit`);
  çalışma anında hiçbir şey indirilmez. Sunucu, modelleri port dinlemeye
  başlamadan önce belleğe yükler: Cloud Run istek dışında CPU'yu kıstığı için
  arka planda yükleme yavaş kalırdı. Açılış (soğuk başlangıç) ~1 dk sürebilir.
- Port `PORT` ortam değişkeninden okunur (varsayılan 8080).
- Hız sınırı için istemci IP'si `X-Forwarded-For` başlığının **en sağdaki**
  girdisinden alınır: Google ön ucu gerçek IP'yi sona ekler, soldaki girdiler
  istemci tarafından sahtelenebilir.
- Yerelde: `docker build -t kus tools/kus_sunucu && docker run -p 8080:8080 kus`.

## Modeller ve lisanslar

- **BioCLIP 2** — Imageomics, MIT lisansı (`hf-hub:imageomics/bioclip-2`)
- **Perch v2** — Google, Apache 2.0 (Kaggle `google/bird-vocalization-classifier`, `perch_v2_cpu`)

## Bakım

`turler.json`, uygulamadaki `ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json`
listesinden üretilir; o liste değişirse `python3 tools/kus_sunucu/turler_guncelle.py`
çalıştırıp eşitleyin; ardından `/saglik` yanıtında `ses_eslesen` 333 değilse
eksik adları `app.py` içindeki `PERCH_ESANLAMLI` eşlemesine ekleyin.
