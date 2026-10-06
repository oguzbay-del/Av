"""BirdNET kuş sesi tanıma API'si (Av Haritası uygulaması için).

POST /analyze  (multipart/form-data)
    file      : ses kaydı (wav/m4a/mp3)
    lat, lon  : isteğe bağlı konum (bölgedeki olası türlere göre filtreler)
    week      : isteğe bağlı BirdNET haftası (1-48)
    min_conf  : en düşük güven (varsayılan 0.25)

Yanıt: {"detections": [{"scientific_name", "common_name", "confidence",
                        "start_time", "end_time"}], "model": "..."}

Model: BirdNET (Cornell Lab of Ornithology & TU Chemnitz), CC BY-NC-SA 4.0.
"""
import os
import tempfile
import threading

from birdnetlib import Recording
from birdnetlib.analyzer import Analyzer
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool

app = FastAPI(title="BirdNET API", version="1.0")
analyzer = Analyzer()  # model bir kez yüklenir
# Analyzer konuma göre tür listesini kendi içinde saklar; istekler birbirini etkilemesin.
lock = threading.Lock()
MAX_BYTES = 10 * 1024 * 1024
API_KEY = os.environ.get("API_KEY")  # tanımlıysa X-API-Key başlığı istenir


@app.get("/")
def health():
    return {"ok": True, "model": "BirdNET (birdnetlib)", "license": "CC BY-NC-SA 4.0"}


@app.post("/analyze")
async def analyze(
    file: UploadFile = File(...),
    lat: float | None = Form(None),
    lon: float | None = Form(None),
    week: int | None = Form(None),
    min_conf: float = Form(0.25),
    x_api_key: str | None = Header(None),
):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(401, "Geçersiz API anahtarı.")
    data = await file.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "Kayıt çok büyük (en fazla 10 MB).")
    suffix = os.path.splitext(file.filename or "")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    kwargs = {"min_conf": max(0.05, min(0.99, min_conf))}
    if lat is not None and lon is not None:
        kwargs.update(lat=lat, lon=lon)
        if week is not None and 1 <= week <= 48:
            kwargs["week_48"] = week
    try:
        rec = await run_in_threadpool(_run, path, kwargs)
    except Exception as e:  # bozuk ses dosyası vb.
        raise HTTPException(400, f"Ses çözümlenemedi: {e}")
    finally:
        os.unlink(path)
    dets = [
        {
            "scientific_name": d["scientific_name"],
            "common_name": d["common_name"],
            "confidence": round(float(d["confidence"]), 4),
            "start_time": d.get("start_time"),
            "end_time": d.get("end_time"),
        }
        for d in rec.detections
    ]
    dets.sort(key=lambda d: -d["confidence"])
    return {"detections": dets, "model": "BirdNET"}


def _run(path, kwargs):
    with lock:
        if "lat" not in kwargs:
            analyzer.custom_species_list = []  # önceki isteğin konum filtresini temizle
        rec = Recording(analyzer, path, **kwargs)
        rec.analyze()
        return rec
