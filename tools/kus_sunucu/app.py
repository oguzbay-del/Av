"""Av Haritası — çevrim içi yedek kuş tanıma sunucusu (Google Cloud Run).

Uygulama yalnızca cihazdaki model emin olmadığında buraya başvurur.
  POST /foto   fotoğraf → BioCLIP 2 sıfır-atış (İstanbul'un 333 türü)
  POST /ses    ses kaydı → Perch v2 (aynı 333 türe daraltılmış)
  GET  /saglik durum bilgisi

Gizlilik: yüklenen dosyalar yalnızca bellekte işlenir; diske yazılmaz,
içerikleri ya da istek ayrıntıları günlüğe kaydedilmez.

Çalıştırma: `python app.py` (PORT ortam değişkeni, varsayılan 8080);
`python app.py --isit` modelleri indirip ısındırır ve çıkar (Docker derlemesi).
"""
import hashlib
import io
import json
import os
import sys
import threading
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from math import gcd
from pathlib import Path

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from starlette.datastructures import UploadFile
from starlette.formparsers import MultiPartParser

DOSYA_SINIRI = 10 * 1024 * 1024          # 10 MB
GOVDE_SINIRI = DOSYA_SINIRI + 64 * 1024  # multipart başlıkları için pay
SES_SINIRI_SN = 30
SES_SR = 32000
PENCERE = 5 * SES_SR
ISTEK_SINIRI, ISTEK_ARALIGI = 30, 600    # IP başına 10 dakikada 30 istek
XFF_SAGDAN = max(1, int(os.environ.get("XFF_SAGDAN", "1")))  # bkz. _istemci_ip
PERCH_URL = "https://www.kaggle.com/models/google/bird-vocalization-classifier/tensorFlow2/perch_v2_cpu/1"
BIOCLIP = "hf-hub:imageomics/bioclip-2"
# Perch etiketleri güncel iNaturalist taksonomisini izler; BirdNET adları farklı olanlar:
PERCH_ESANLAMLI = {
    "Accipiter gentilis": "Astur gentilis",
    "Apus melba": "Tachymarptis melba",
    "Bubulcus ibis": "Ardea ibis",
    "Charadrius alexandrinus": "Anarhynchus alexandrinus",
    "Charadrius dubius": "Thinornis dubius",
    "Charadrius leschenaultii": "Anarhynchus leschenaultii",
    "Charadrius morinellus": "Eudromias morinellus",
    "Corvus monedula": "Coloeus monedula",
    "Ixobrychus minutus": "Botaurus minutus",
    "Streptopelia senegalensis": "Spilopelia senegalensis",
}
# BioCLIP tarzı metin: bilimsel + yaygın ad; birkaç şablonun ortalaması alınır.
SABLONLAR = (
    "a photo of {}.",
    "a photo of a {}.",
    "a close-up photo of a {}.",
    "a bad photo of a {}.",
    "a photo of the small {}.",
)

# Starlette dosya parçalarını 1 MB'ı aşınca diske taşır; sınırı yükselterek
# yüklemelerin her zaman bellekte kalmasını sağlıyoruz (gövde zaten sınırlı).
MultiPartParser.spool_max_size = GOVDE_SINIRI + 1

TURLER = json.loads(Path(__file__).with_name("turler.json").read_text(encoding="utf-8"))
_kilit = threading.Lock()
_m: dict = {}


def _foto_yukle():
    import open_clip
    import torch

    model, _, onisleme = open_clip.create_model_and_transforms(BIOCLIP)
    model.eval()
    tokenizer = open_clip.get_tokenizer(BIOCLIP)
    adlar = [f"{t['sci']} with common name {t['en']}" for t in TURLER]
    # Metin gömmeleri bir kez hesaplanıp HF önbelleğine yazılır (soğuk açılış kısa olsun).
    anahtar = hashlib.sha1(json.dumps([adlar, SABLONLAR]).encode()).hexdigest()[:12]
    onbellek = Path(os.environ.get("HF_HOME", Path.home() / ".cache/huggingface")) / f"bioclip2_metin_{anahtar}.npy"
    if onbellek.exists():
        metin = torch.from_numpy(np.load(onbellek))
    else:
        parcalar = []
        for ad in adlar:
            with torch.no_grad():
                e = model.encode_text(tokenizer([s.format(ad) for s in SABLONLAR]))
            e = torch.nn.functional.normalize(e, dim=-1).mean(0)
            parcalar.append(e / e.norm())
        metin = torch.stack(parcalar)
        onbellek.parent.mkdir(parents=True, exist_ok=True)
        np.save(onbellek, metin.numpy())
    _m.update(clip=model, onisleme=onisleme, metin=metin, olcek=float(model.logit_scale.detach().exp()))


def _ses_yukle():
    import tensorflow as tf
    import tensorflow_hub as hub

    model = hub.load(PERCH_URL)
    imza = model.signatures["serving_default"]
    etiket_yolu = Path(hub.resolve(PERCH_URL)) / "assets" / "labels.csv"
    etiketler = [s.strip().lower() for s in etiket_yolu.read_text(encoding="utf-8").splitlines()[1:]]
    sira = {ad: i for i, ad in enumerate(etiketler)}
    adlar = [PERCH_ESANLAMLI.get(t["sci"], t["sci"]).lower() for t in TURLER]
    eslesen = [(j, sira[ad]) for j, ad in enumerate(adlar) if ad in sira]
    imza(inputs=tf.zeros([1, PENCERE]))  # ısındırma
    _m.update(perch=imza, tf=tf, ses_tur=[j for j, _ in eslesen], ses_idx=np.array([i for _, i in eslesen]))


def modeller() -> dict:
    """Modelleri bir kez yükler; eşzamanlı çağrılar kilitte bekler."""
    with _kilit:
        if "hazir" not in _m:
            _foto_yukle()
            _ses_yukle()
            _m["hazir"] = True
    return _m


@asynccontextmanager
async def lifespan(_):
    # Modeller port dinlenmeden ÖNCE yüklenir (uvicorn soketi lifespan başlangıcı
    # bitince açar). Cloud Run istek dışında CPU'yu kısar; arka plan iş parçacığında
    # yükleme sürünürdü. Başlangıçta ise CPU tam verilir (--cpu-boost ile iki katı)
    # ve kapsayıcının 4 dakika içinde dinlemeye başlaması yeterlidir. Modeller
    # imajda hazır olduğundan bu ~30–60 sn sürer; ardından /saglik anında yanıt verir.
    await run_in_threadpool(modeller)
    yield


app = FastAPI(title="Av Haritası Kuş", docs_url=None, redoc_url=None, lifespan=lifespan)
_istekler: dict[str, deque] = defaultdict(deque)
_cikarim = threading.Lock()  # CPU'da istekleri sırayla işle (bellek tepe değeri düşük kalsın)


def _hata(kod: int, mesaj: str):
    raise HTTPException(kod, detail=mesaj)


@app.exception_handler(HTTPException)
async def _hata_yaniti(_, e: HTTPException):
    return JSONResponse({"hata": e.detail}, status_code=e.status_code)


def _istemci_ip(request: Request) -> str:
    """Hız sınırı için istemci IP'si.

    Cloud Run'ın önündeki Google ön ucu (GFE) gerçek istemci IP'sini
    X-Forwarded-For başlığının SONUNA ekler; istemcinin kendi gönderdiği
    soldaki girdiler olduğu gibi kalır ve kolayca sahtelenebilir. Bu yüzden
    en sağdaki girdi kullanılır. Önüne ayrıca bir yük dengeleyici konursa
    (o da kendi IP'sini ekler) XFF_SAGDAN=2 yapın.
    """
    girdiler = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
    if girdiler:
        return girdiler[-min(XFF_SAGDAN, len(girdiler))]
    return request.client.host if request.client else "?"


def _hiz_siniri(request: Request):
    ip = _istemci_ip(request)
    simdi = time.monotonic()
    q = _istekler[ip]
    while q and simdi - q[0] > ISTEK_ARALIGI:
        q.popleft()
    if len(q) >= ISTEK_SINIRI:
        _hata(429, "Çok fazla istek. Lütfen birkaç dakika sonra tekrar deneyin.")
    q.append(simdi)
    if len(_istekler) > 10000:  # eski IP kayıtlarını temizle
        for k in [k for k, v in _istekler.items() if not v or simdi - v[-1] > ISTEK_ARALIGI]:
            del _istekler[k]


async def _dosya_al(request: Request) -> bytes:
    """İstek gövdesini sınırlı biçimde belleğe okur ve 'file' alanını döndürür."""
    _hiz_siniri(request)
    if "multipart/form-data" not in request.headers.get("content-type", ""):
        _hata(400, "İstek multipart/form-data olmalı ('file' alanı).")
    govde = bytearray()
    async for parca in request.stream():
        govde += parca
        if len(govde) > GOVDE_SINIRI:
            _hata(413, "Dosya 10 MB sınırını aşıyor.")

    async def al():
        return {"type": "http.request", "body": bytes(govde), "more_body": False}

    try:
        form = await Request(request.scope, al).form(max_files=1, max_fields=4)
    except Exception:
        _hata(400, "Form verisi okunamadı.")
    dosya = form.get("file")
    if not isinstance(dosya, UploadFile):
        _hata(400, "'file' alanında dosya bulunamadı.")
    veri = await dosya.read()
    await form.close()
    if not veri:
        _hata(400, "Dosya boş.")
    if len(veri) > DOSYA_SINIRI:
        _hata(413, "Dosya 10 MB sınırını aşıyor.")
    return veri


def _sonuclar(olasilik: np.ndarray, turler: list[int], k: int = 5) -> list[dict]:
    en_iyi = np.argsort(-olasilik)[:k]
    return [{**TURLER[turler[i]], "p": round(float(olasilik[i]), 4)} for i in en_iyi]


def _softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - x.max())
    return e / e.sum()


def _foto_tahmin(veri: bytes) -> list[dict]:
    import torch
    from PIL import Image

    Image.MAX_IMAGE_PIXELS = 50_000_000
    try:
        with Image.open(io.BytesIO(veri)) as g:
            g = g.convert("RGB")
    except Exception:
        _hata(400, "Görüntü okunamadı; JPEG, PNG veya WebP gönderin.")
    m = modeller()
    with _cikarim, torch.no_grad():
        gorsel = m["clip"].encode_image(m["onisleme"](g).unsqueeze(0))
    gorsel = (gorsel / gorsel.norm(dim=-1, keepdim=True))[0].numpy()
    return _sonuclar(_softmax(m["olcek"] * (m["metin"].numpy() @ gorsel)), list(range(len(TURLER))))


def _ses_tahmin(veri: bytes) -> tuple[list[dict], int]:
    import soundfile as sf
    from scipy.signal import resample_poly

    try:
        bilgi = sf.info(io.BytesIO(veri))
        if bilgi.frames / bilgi.samplerate > SES_SINIRI_SN + 0.5:
            _hata(400, f"Ses kaydı en fazla {SES_SINIRI_SN} saniye olmalı.")
        x, sr = sf.read(io.BytesIO(veri), dtype="float32", always_2d=True)
    except HTTPException:
        raise
    except Exception:
        _hata(400, "Ses dosyası okunamadı (WAV, FLAC, OGG veya MP3 gönderin).")
    x = x.mean(axis=1)
    if sr != SES_SR:
        b = gcd(SES_SR, sr)
        x = resample_poly(x, SES_SR // b, sr // b).astype(np.float32)
    if len(x) < SES_SR // 2:
        _hata(400, "Ses kaydı çok kısa (en az 0,5 saniye).")
    n = -(-len(x) // PENCERE)
    pencereler = np.zeros((n, PENCERE), np.float32)
    pencereler.flat[: len(x)] = x
    tepe = np.abs(pencereler).max(axis=1, keepdims=True)
    pencereler = np.where(tepe > 0, pencereler * (0.25 / np.maximum(tepe, 1e-9)), pencereler)
    m = modeller()
    with _cikarim:
        logit = m["perch"](inputs=m["tf"].constant(pencereler))["label"].numpy()
    skor = logit[:, m["ses_idx"]].max(axis=0)
    return _sonuclar(_softmax(skor), m["ses_tur"]), n


@app.post("/foto")
async def foto(request: Request):
    veri = await _dosya_al(request)
    t = time.perf_counter()
    sonuclar = await run_in_threadpool(_foto_tahmin, veri)
    return {"model": "bioclip-2", "sonuclar": sonuclar, "sure_ms": int((time.perf_counter() - t) * 1000)}


@app.post("/ses")
async def ses(request: Request):
    veri = await _dosya_al(request)
    t = time.perf_counter()
    sonuclar, n = await run_in_threadpool(_ses_tahmin, veri)
    return {"model": "perch-v2", "sonuclar": sonuclar, "pencere": n, "sure_ms": int((time.perf_counter() - t) * 1000)}


@app.get("/saglik")
def saglik():
    hazir = "hazir" in _m
    return {
        "durum": "hazir" if hazir else "yukleniyor",
        "foto_model": "bioclip-2",
        "ses_model": "perch-v2",
        "turler": len(TURLER),
        "ses_eslesen": len(_m["ses_tur"]) if hazir else None,
    }


if __name__ == "__main__":
    if "--isit" in sys.argv:  # Docker derlemesinde modelleri indirip ısındırmak için
        modeller()
        print(f"Modeller hazır; Perch eşleşen tür: {len(_m['ses_tur'])}/{len(TURLER)}")
    else:
        import uvicorn

        uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=False)
