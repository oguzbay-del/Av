---
title: BirdNET API
emoji: 🐦
colorFrom: green
colorTo: blue
sdk: docker
app_port: 7860
license: cc-by-nc-sa-4.0
---

# BirdNET kuş sesi API'si

Av Haritası uygulamasının **Kuş Sesi** sekmesi 15 sn'lik kaydı bu sunucuya gönderir.
Sunucu Cornell Lab of Ornithology ve TU Chemnitz'in önceden eğitilmiş
[BirdNET](https://github.com/kahst/BirdNET-Analyzer) modelini
([birdnetlib](https://github.com/joeweiss/birdnetlib) ile) çalıştırır: 6.000'den fazla tür,
eğitim gerektirmez. Konum ve hafta gönderildiğinde yalnızca o bölgede o mevsimde
beklenen türler arasından tahmin yapılır (İstanbul, Ekim: ~230 tür).

> **Lisans:** BirdNET modeli CC BY-NC-SA 4.0'dır — yalnızca ticari olmayan kullanım.
> Uygulama ücretli/ticari dağıtılacaksa Cornell Lab'den lisans alınmalıdır.

## Neden sunucu?

| Seçenek | Durum |
|---|---|
| **BirdNET (bu sunucu)** | Tür düzeyinde, bölgeye göre filtreli, ücretsiz. ✅ seçildi |
| Apple SoundAnalysis (cihazda) | İnternetsiz yedek; yalnızca "ördek / kaz / baykuş / karga" gibi grup verir. Uygulamada otomatik devreye girer. |
| Xeno-canto API | Kayıt *arşivi*; tanıma yapmaz (v2 kapandı, v3 anahtar ister). Model eğitmek için veri kaynağıdır. |
| BirdNET'i CoreML'e çevirip cihaza gömmek | Mümkün (TFLite → CoreML) ama ~50 MB model, lisans ve bakım yükü; sonraki adım. |

## Çalıştırma

### Yerel (ev bilgisayarı / Raspberry Pi)

```bash
cd server/birdnet-api
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 7860
```

Uygulamada **Ayarlar → Kuş sesi tanıma** alanına `http://<bilgisayarın-ip>:7860/` yazın
(telefon aynı Wi-Fi'da olmalı; iOS düz `http` için yerel ağ izni sorar).

### Docker

```bash
docker build -t birdnet-api server/birdnet-api
docker run -p 7860:7860 birdnet-api
```

### Hugging Face Spaces (ücretsiz, internetten erişilebilir)

1. huggingface.co → **New Space** → SDK: **Docker** → boş.
2. Bu klasördeki `app.py`, `requirements.txt`, `Dockerfile`, `README.md` dosyalarını yükleyin.
3. İsterseniz *Settings → Variables and secrets* altında `API_KEY` tanımlayın.
4. Adres: `https://<kullanıcı>-<space>.hf.space/` → uygulamanın Ayarlar'ına yazın.

## API

```
GET  /          → {"ok": true, ...}
POST /analyze   multipart: file (wav/m4a/mp3, ≤10 MB), lat, lon, week (1-48), min_conf (0.25)
                başlık: X-API-Key (yalnızca API_KEY tanımlıysa)
→ {"detections": [{"scientific_name": "Coturnix coturnix", "common_name": "Common Quail",
                    "confidence": 0.91, "start_time": 3.0, "end_time": 6.0}], "model": "BirdNET"}
```

Örnek:

```bash
curl -F file=@kayit.wav -F lat=41.2 -F lon=28.9 -F week=40 http://localhost:7860/analyze
```

Uygulama, gelen bilimsel adı MAK 2026-27'nin EK-1 (koruma altındaki) ve EK-2 (av türleri)
listeleriyle eşleştirip "bugün avlanabilir / sezon dışı / İstanbul'da yasak / koruma altında"
durumunu gösterir.
