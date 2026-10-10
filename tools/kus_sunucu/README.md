# Av Haritası — çevrim içi yedek kuş tanıma sunucusu

Av Haritası iOS uygulaması kuşları önce cihaz üzerinde tanır. Cihazdaki model
emin olmadığında fotoğraf ya da ses kaydı bu sunucuya gönderilir; sonuçlar
İstanbul'da görülen **333 türle** sınırlıdır. Sunucu Google Cloud Run'da
(`europe-west1`, Belçika) çalışır; kullanılmadığında sıfır örneğe iner.

| Uç nokta | Girdi | Model |
|---|---|---|
| `POST /foto` | multipart `file`, görüntü ≤ 10 MB | BioCLIP 2 sıfır-atış |
| `POST /ses` | multipart `file`, ses ≤ 10 MB ve ≤ 30 sn | Perch v2 (5 sn pencere, 32 kHz) |
| `GET /saglik` | — | durum, tür sayısı, Perch eşleşen tür sayısı |

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
saklanmaz ve günlüğe kaydedilmez**. Erişim günlüğü kapalıdır. (Cloud Run kendi
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
