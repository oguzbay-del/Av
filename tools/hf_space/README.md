---
title: Av Haritasi Kus
colorFrom: green
colorTo: yellow
sdk: docker
app_port: 7860
license: apache-2.0
short_description: Istanbul kus turleri icin yedek foto/ses tanima
---

# Av Haritası — çevrim içi yedek kuş tanıma

Av Haritası iOS uygulaması kuşları önce cihaz üzerinde tanır. Cihazdaki model
emin olmadığında fotoğraf ya da ses kaydı bu sunucuya gönderilir; sonuçlar
İstanbul'da görülen **333 türle** sınırlıdır.

Örnek Space: `Oguzbayrakdar/av-haritasi-kus` → https://oguzbayrakdar-av-haritasi-kus.hf.space

| Uç nokta | Girdi | Model |
|---|---|---|
| `POST /foto` | multipart `file`, görüntü ≤ 10 MB | BioCLIP 2 sıfır-atış |
| `POST /ses` | multipart `file`, ses ≤ 10 MB ve ≤ 30 sn | Perch v2 (5 sn pencere, 32 kHz) |
| `GET /saglik` | — | durum, tür sayısı, Perch eşleşen tür sayısı |

Yanıt: `{"model": "...", "sonuclar": [{"sci","en","tr","p"}], "sure_ms": 123}`
(`/ses` ayrıca `pencere` sayısını döndürür). Hatalar `{"hata": "..."}` biçimindedir.
IP başına 10 dakikada 30 istek sınırı vardır.

```sh
curl -F file=@saksagan.jpg https://oguzbayrakdar-av-haritasi-kus.hf.space/foto
```

## Gizlilik

Yüklenen dosyalar yalnızca bellekte işlenir; **hiçbir zaman diske yazılmaz,
saklanmaz ve günlüğe kaydedilmez**. Erişim günlüğü kapalıdır.

## Modeller ve lisanslar

- **BioCLIP 2** — Imageomics, MIT lisansı (`hf-hub:imageomics/bioclip-2`)
- **Perch v2** — Google, Apache 2.0 (Kaggle `google/bird-vocalization-classifier`, `perch_v2_cpu`)

## Bakım

`turler.json`, uygulamadaki `ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json`
listesinden üretilir; o liste değişirse `python3 tools/hf_space/turler_guncelle.py`
çalıştırıp eşitleyin; ardından `/saglik` yanıtında `ses_eslesen` 333 değilse
eksik adları `app.py` içindeki `PERCH_ESANLAMLI` eşlemesine ekleyin. `main` dalına itilen değişiklikler
`.github/workflows/hf-space.yml` ile Space'e yüklenir (`HF_TOKEN` sırrı ve
`HF_SPACE` değişkeni gerekir).
