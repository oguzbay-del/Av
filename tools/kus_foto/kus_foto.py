#!/usr/bin/env python3
"""Kuş fotoğrafı tür modeli: veri indirme, GPU eğitimi, değerlendirme ve Core ML dışa aktarımı.

Google Colab (ücretsiz T4) için yazıldı; Kaggle veya başka bir GPU makinesinde de çalışır.
Adımlar ayrı ayrı çalıştırılır ve her biri kaldığı yerden devam eder (Colab bağlantısı koparsa
aynı hücreyi yeniden çalıştırmak yeterli):

  python kus_foto.py indir        iNaturalist fotoğrafları  → <veri>/foto/<etiket>/*.jpg
  python kus_foto.py ogretmen     BioCLIP 2 yumuşak etiketleri (isteğe bağlı) → <yedek>/ogretmen.pt
  python kus_foto.py egit         EfficientNetV2 ince ayar  → <yedek>/kontrol.pt (her tur)
  python kus_foto.py degerlendir  test, sıcaklık ayarı      → <cikti>/metrikler.json ...
  python kus_foto.py performans   int8 kaybı, zor koşullar, hız, boyut → <cikti>/performans.json
  python kus_foto.py aktar        Core ML (fp16 + int8)     → <cikti>/BirdClassifier.mlpackage
  python kus_foto.py yukle        zip + GitHub sürümü       → harita-veri sürüm varlığı

Türler: uygulamadaki İstanbul listesi (BirdNET_Istanbul_Weeks.json, 333 tür; MAK av ve koruma
listelerini kapsar). Etiket biçimi uygulamanın beklediği "<Bilimsel ad>_<İngilizce ad>".

Ayarlar ortam değişkenleriyle verilir (Colab defterindeki ilk hücre):
  MODEL, IMG, EPOCHS, BATCH, LR, GPUS, KD, PER_SPECIES, MIN_PHOTOS, LICENSES, VERI, YEDEK, CIKTI, DEPO

Birden çok GPU: egit adımı GPUS>1 ise kendini torchrun ile GPU başına bir süreçle yeniden başlatır
(DistributedDataParallel). GPUS=1 eski tek GPU yolunu kullanır. BATCH GPU başınadır.
"""
import csv
import hashlib
import io
import json
import math
import os
import shutil
import sys
import threading
import time
import zipfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

# ---------------------------------------------------------------- ayarlar

E = os.environ.get
MODEL = E("MODEL", "tf_efficientnetv2_s.in21k_ft_in1k")  # ImageNet-21k: yüzlerce kuş türü görmüş
IMG = int(E("IMG", "384"))
EPOCHS = int(E("EPOCHS", "30"))
BATCH = int(E("BATCH", "0"))  # GPU başına; 0: GPU belleğine ve IMG'ye göre
LR = float(E("LR", "0"))  # 0: toplam batch'e göre
# Uzaktan/telefonla çekilmiş fotoğraf benzetimi (GPU'da): bulanıklık, küçültüp büyütme, uzaklaştırma
BLUR_P = float(E("BLUR_P", "0.25"))
DOWN_P = float(E("DOWN_P", "0.25"))
ZOOMOUT_P = float(E("ZOOMOUT_P", "0.1"))
# BioCLIP 2 bilgi damıtma: ogretmen adımının dosyası varsa KL kaybı (ağırlık KD, sıcaklık KD_T)
KD = float(E("KD", "0.5"))
KD_T = float(E("KD_T", "2"))
KD_MIN = float(E("KD_MIN", "0.5"))  # öğretmenin doğrulama doğruluğu bunun altındaysa damıtma yapılmaz
BIOCLIP = "hf-hub:imageomics/bioclip-2"
PER_SPECIES = int(E("PER_SPECIES", "400"))
MIN_PHOTOS = int(E("MIN_PHOTOS", "25"))
# Ticari kullanım düşünülüyorsa LICENSES="cc0,cc-by" (CC BY-NC fotoğraflar ticari kullanımı yasaklar)
LICENSES = E("LICENSES", "cc0,cc-by,cc-by-nc")
LIMIT_SPECIES = int(E("LIMIT_SPECIES", "0"))  # yalnızca deneme için
MAX_STEPS = int(E("MAX_STEPS", "0"))  # yalnızca hız denemesi için: tur başına en çok adım
DEPO = E("DEPO", os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
VERI = E("VERI", "/content/veri")  # yerel disk (hızlı)
YEDEK = E("YEDEK", "/content/drive/MyDrive/AvHaritasi_kus_foto")  # Google Drive (kalıcı)
CIKTI = E("CIKTI", os.path.join(YEDEK, "cikti"))
OGRETMEN = E("OGRETMEN", os.path.join(YEDEK, "ogretmen.pt"))
SURUM_DEPO = E("SURUM_DEPO", "oguzbay-del/harita-veri")

API = "https://api.inaturalist.org/v1"
UA = {"User-Agent": "AvHaritasi-egitim/2.0 (github.com/oguzbay-del/harita-veri)"}
PLACES = [("Türkiye", 7183), ("Avrupa", 97391), ("Dünya", None)]
FOTO = os.path.join(VERI, "foto")
META = os.path.join(VERI, "meta")
MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def species():
    """[(bilimsel, ingilizce, türkçe)] — uygulamadaki İstanbul tür listesi."""
    d = json.load(open(os.path.join(DEPO, "ios/AvHaritasi/BirdNET/BirdNET_Istanbul_Weeks.json"), encoding="utf-8"))
    out = [(s["sci"], s["en"], s.get("tr") or s["en"]) for s in d["species"]]
    return out[:LIMIT_SPECIES] if LIMIT_SPECIES else out


def label_of(sci, en):
    return f"{sci}_{en.replace('/', '-').replace('_', ' ')}"


def mak():
    m = json.load(open(os.path.join(DEPO, "ios/AvHaritasi/MapData/mak_2026_2027.json"), encoding="utf-8"))
    return set(m.get("huntableLatin", {})), set(m.get("protectedLatin", {}))


# ---------------------------------------------------------------- 1. indir

_api_lock = threading.Lock()
_api_last = [0.0]


def api(path, params, tries=6):
    import requests
    for i in range(tries):
        with _api_lock:  # iNaturalist isteği: saniyede en fazla ~1 istek
            wait = 1.05 - (time.time() - _api_last[0])
            if wait > 0:
                time.sleep(wait)
            _api_last[0] = time.time()
        try:
            r = requests.get(f"{API}/{path}", params=params, headers=UA, timeout=40)
            if r.status_code in (429, 500, 502, 503):
                time.sleep(15 * (i + 1))
                continue
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001 - ağ hataları yeniden denenir
            if i == tries - 1:
                raise
            log("  yeniden deneniyor:", e)
            time.sleep(2 ** i)


def find_taxon(sci):
    res = api("taxa", {"q": sci, "rank": "species", "per_page": 10, "is_active": "true"})["results"]
    for t in res:
        names = {t["name"].lower(), (t.get("matched_term") or "").lower()}
        if sci.lower() in names and t.get("iconic_taxon_name") == "Aves":
            return t
    return None


def collect(sci):
    """Tür için fotoğraf listesi (önbellekli). Gözlem başına en çok 2 fotoğraf; aynı gözlem
    hiçbir zaman hem eğitim hem testte olmaz (ayrım gözleme göre)."""
    os.makedirs(META, exist_ok=True)
    path = os.path.join(META, sci.replace(" ", "_") + ".json")
    if os.path.exists(path):
        m = json.load(open(path))
        if m.get("per_species", 0) >= PER_SPECIES and m.get("licenses") == LICENSES:
            return m
    t = find_taxon(sci)
    m = {"sci": sci, "taxon": t and t["id"], "per_species": PER_SPECIES, "licenses": LICENSES, "photos": []}
    if t:
        allowed = set(LICENSES.split(","))
        seen_obs = set()
        for place, pid in PLACES:
            page = 1
            while len(m["photos"]) < PER_SPECIES and page <= 10:
                params = {"taxon_id": t["id"], "quality_grade": "research", "photo_license": LICENSES,
                          "photos": "true", "per_page": 200, "page": page, "order_by": "votes"}
                if pid:
                    params["place_id"] = pid
                res = api("observations", params).get("results", [])
                if not res:
                    break
                for o in res:
                    if o["id"] in seen_obs:
                        continue
                    seen_obs.add(o["id"])
                    for ph in [p for p in o.get("photos", []) if (p.get("license_code") or "").lower() in allowed][:2]:
                        m["photos"].append({"id": ph["id"], "obs": o["id"], "lic": ph["license_code"],
                                            "user": (o.get("user") or {}).get("login", ""),
                                            "url": ph["url"].replace("/square.", "/medium.")})
                    if len(m["photos"]) >= PER_SPECIES:
                        break
                page += 1
            if len(m["photos"]) >= PER_SPECIES:
                break
    json.dump(m, open(path, "w"))
    return m


def fetch_photo(item, folder):
    """İndir, kısa kenarı IMG+48 piksele küçült (eğitimde çözme hızını 3-4 kat artırır)."""
    import requests
    from PIL import Image
    dst = os.path.join(folder, f"{item['id']}.jpg")
    if os.path.exists(dst):
        return True
    for i in range(3):
        try:
            r = requests.get(item["url"], headers=UA, timeout=40)
            if r.status_code == 404:
                return False
            r.raise_for_status()
            im = Image.open(io.BytesIO(r.content)).convert("RGB")
            short = IMG + 48
            s = short / min(im.size)
            if s < 1:
                im = im.resize((round(im.width * s), round(im.height * s)), Image.BICUBIC)
            if min(im.size) < IMG * 0.6:
                return False  # çok küçük
            tmp = dst + ".tmp"
            im.save(tmp, "JPEG", quality=92)
            os.replace(tmp, dst)
            return True
        except Exception:  # noqa: BLE001
            time.sleep(2 ** i)
    return False


def cmd_indir():
    restore_backup()
    sp = species()
    log(f"{len(sp)} tür, tür başına en çok {PER_SPECIES} fotoğraf, lisanslar: {LICENSES}")
    pool = ThreadPoolExecutor(16)
    summary = []
    for n, (sci, en, tr) in enumerate(sp, 1):
        m = collect(sci)
        folder = os.path.join(FOTO, label_of(sci, en))
        os.makedirs(folder, exist_ok=True)
        ok = sum(pool.map(lambda it: fetch_photo(it, folder), m["photos"]))
        summary.append((sci, tr, ok))
        log(f"[{n}/{len(sp)}] {sci} ({tr}): {ok} fotoğraf" + ("" if m["taxon"] else " — iNaturalist'te bulunamadı"))
        if n % 40 == 0:
            backup()
    backup()
    few = [s for s in summary if s[2] < MIN_PHOTOS]
    log(f"Toplam {sum(s[2] for s in summary)} fotoğraf. En az {MIN_PHOTOS} fotoğrafı olmayan {len(few)} tür "
        f"eğitime alınmaz: " + ", ".join(f"{s[1]} ({s[2]})" for s in few[:40]))


def backup():
    """Fotoğrafları Drive'a tek arşiv olarak yedekle (çok sayıda küçük dosya Drive'da yavaştır)."""
    if E("YEDEK_VERI", "1") == "0" or not os.path.isdir(os.path.dirname(YEDEK)):
        return
    os.makedirs(YEDEK, exist_ok=True)
    tmp = os.path.join(VERI, "veri_yedek.tar")
    shutil.make_archive(tmp[:-4], "tar", VERI, ".")  # meta + foto
    shutil.copy(tmp, os.path.join(YEDEK, "veri_yedek.tar"))
    os.remove(tmp)
    log("Drive yedeği güncellendi")


def restore_backup():
    src = os.path.join(YEDEK, "veri_yedek.tar")
    if os.path.isdir(FOTO) and os.listdir(FOTO):
        return
    if os.path.exists(src):
        log("Drive yedeğinden geri yükleniyor…")
        os.makedirs(VERI, exist_ok=True)
        shutil.unpack_archive(src, VERI, "tar")


# ---------------------------------------------------------------- veri kümesi

def split_of(obs_id):
    """Gözleme göre sabit ayrım: %10 test, %5 doğrulama, %85 eğitim."""
    h = int(hashlib.sha1(str(obs_id).encode()).hexdigest()[:8], 16) % 100
    return "test" if h < 10 else "val" if h < 15 else "train"


def dataset():
    """(sınıflar, {train/val/test: [(yol, sınıf)]}). Yalnızca diskte bulunan fotoğraflar."""
    restore_backup()
    sp = species()
    classes, items = [], defaultdict(list)
    for sci, en, tr in sp:
        lab = label_of(sci, en)
        folder = os.path.join(FOTO, lab)
        mp = os.path.join(META, sci.replace(" ", "_") + ".json")
        if not os.path.isdir(folder) or not os.path.exists(mp):
            continue
        obs = {str(p["id"]): p["obs"] for p in json.load(open(mp))["photos"]}
        files = [f for f in os.listdir(folder) if f.endswith(".jpg") and f[:-4] in obs]
        if len(files) < MIN_PHOTOS:
            continue
        c = len(classes)
        classes.append({"label": lab, "sci": sci, "en": en, "tr": tr})
        for f in sorted(files):
            items[split_of(obs[f[:-4]])].append((os.path.join(folder, f), c))
    return classes, items


def loaders(items, n_classes, batch, train=True, rank=0, world=1):
    """CPU'da yalnızca çözme + kırpma + çevirme (uint8); renk oynatma, normalleştirme ve rastgele silme
    GPU'da yapılır (gpu_prep). İlk Kaggle denemesinde ağır CPU dönüşümleri ve işçi başına çok iş
    parçacığı yüzünden hız saniyede ~27 görüntüde kalmıştı."""
    import torch
    from PIL import Image
    from torchvision import transforms as T

    tf_train = T.Compose([
        T.RandomResizedCrop(IMG, scale=(0.3, 1.0), antialias=True),
        T.RandomHorizontalFlip(),
        T.PILToTensor(),
    ])
    # Uygulamadaki Vision "centerCrop" ile aynı: kısa kenar IMG, ortadan kare
    tf_eval = T.Compose([T.Resize(IMG, interpolation=T.InterpolationMode.BICUBIC), T.CenterCrop(IMG), T.PILToTensor()])

    class DS(torch.utils.data.Dataset):
        def __init__(self, rows, tf, index=False):
            self.rows, self.tf, self.index = rows, tf, index

        def __len__(self):
            return len(self.rows)

        def __getitem__(self, i):
            p, c = self.rows[i]
            with Image.open(p) as im:
                x = self.tf(im.convert("RGB"))
            return (x, c, i) if self.index else (x, c)  # sıra: öğretmen etiketini bulmak için

    # Çok GPU'da çekirdekler süreçler arasında paylaştırılır
    workers = min(8, max(1, (os.cpu_count() or 2) // world))
    # pin_memory kapalı: Kaggle'da ana süreç belleği her adımda ~1 grup kadar büyüyüp tükendi
    kw = dict(num_workers=workers, pin_memory=False, worker_init_fn=_one_thread)
    if workers:
        kw["prefetch_factor"] = 2
    out = {}
    if train:
        rows = items["train"]
        counts = Counter(c for _, c in rows)
        # Az fotoğraflı türler daha sık örneklenir (1/√n): nadir koruma altındaki türler unutulmasın
        w = torch.tensor([1.0 / math.sqrt(counts[c]) for _, c in rows], dtype=torch.double)
        if world > 1:
            sampler = DistWeightedSampler(w, rank, world)
        else:
            sampler = torch.utils.data.WeightedRandomSampler(w, num_samples=len(rows), replacement=True)
        out["train"] = torch.utils.data.DataLoader(DS(rows, tf_train, index=True), batch_size=batch, sampler=sampler,
                                                   drop_last=True, persistent_workers=workers > 0, **kw)
    # Değerlendirme işçileri kalıcı değil: her biri ana sürecin belleğini kopyalar (ilk denemede bellek yetmedi)
    for s in ("val", "test"):
        out[s] = torch.utils.data.DataLoader(DS(items[s], tf_eval), batch_size=batch * 2, shuffle=False, **kw)
    return out, tf_eval


class DistWeightedSampler:
    """Çok GPU için ağırlıklı örnekleme (1/√n dengesi korunur): her tur tüm süreçler aynı tohumla
    aynı ağırlıklı sırayı çeker, her süreç kendi dilimini (rank::world) alır."""

    def __init__(self, weights, rank, world, seed=0):
        self.w, self.rank, self.world, self.seed, self.epoch = weights, rank, world, seed, 0
        self.n = len(weights) // world

    def set_epoch(self, epoch):
        self.epoch = epoch

    def __iter__(self):
        import torch
        g = torch.Generator()
        g.manual_seed(self.seed + self.epoch)
        idx = torch.multinomial(self.w, self.n * self.world, replacement=True, generator=g)
        return iter(idx[self.rank::self.world].tolist())

    def __len__(self):
        return self.n


def _one_thread(_):
    import torch
    torch.set_num_threads(1)  # işçi başına tek iş parçacığı: çekirdekler birbirini beklemesin


_erase = {}


def gpu_prep(x, train):
    """uint8 NCHW → normalleştirilmiş float (GPU). Eğitimde örnek başına parlaklık/karşıtlık/doygunluk
    oynatma ve rastgele silme."""
    import torch
    dev = device()
    x = x.to(dev).float().div_(255)
    if train:
        n = x.size(0)
        r = lambda lo, hi: torch.empty(n, 1, 1, 1, device=dev).uniform_(lo, hi)  # noqa: E731
        x = x * r(0.7, 1.3)  # parlaklık
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) * r(0.7, 1.3) + mean  # karşıtlık
        gray = (x * torch.tensor([0.299, 0.587, 0.114], device=dev).view(1, 3, 1, 1)).sum(1, keepdim=True)
        x = (x - gray) * r(0.6, 1.4) + gray  # doygunluk
        x = x.clamp_(0, 1)
        x = distant_aug(x)
    x = (x - torch.tensor(MEAN, device=dev).view(1, 3, 1, 1)) / torch.tensor(STD, device=dev).view(1, 3, 1, 1)
    if train:
        if dev not in _erase:
            from timm.data.random_erasing import RandomErasing
            _erase[dev] = RandomErasing(probability=0.25, mode="pixel", device=dev.type)
        x = _erase[dev](x)
    return x.contiguous(memory_format=torch.channels_last)


def distant_aug(x):
    """Uzaktaki/telefonla çekilmiş kuş benzetimi (GPU, 0–1 aralığında NCHW):
    örnek başına rastgele Gauss bulanıklığı, küçültüp geri büyütme (düşük çözünürlük) ve
    uzaklaştırma (kuş kadrajda küçülür, kenarlar görüntünün ortalama rengiyle dolar)."""
    import torch
    import torch.nn.functional as F
    n, ch, h, w = x.shape
    dev = x.device
    m = torch.rand(n, device=dev) < BLUR_P
    if m.any():
        k = 19  # σ ≤ 3 için yeterli (3σ yarıçap)
        sig = torch.empty(int(m.sum()), 1, device=dev).uniform_(0.6, 3.0)
        t = torch.arange(k, device=dev, dtype=x.dtype) - k // 2
        g = torch.exp(-t[None] ** 2 / (2 * sig ** 2))
        g = (g / g.sum(1, keepdim=True)).repeat_interleave(ch, 0)  # (seçilen*3, k)
        xs = x[m].reshape(1, -1, h, w)
        xs = F.pad(xs, (k // 2,) * 4, mode="reflect")
        xs = F.conv2d(xs, g.view(-1, 1, k, 1), groups=g.size(0))
        xs = F.conv2d(xs, g.view(-1, 1, 1, k), groups=g.size(0))
        x[m] = xs.view(-1, ch, h, w)
    m = torch.rand(n, device=dev) < DOWN_P
    if m.any():
        f = float(torch.empty(1).uniform_(0.25, 0.6))  # grup başına tek oran
        small = F.interpolate(x[m], size=(max(8, round(h * f)), max(8, round(w * f))), mode="bilinear",
                              antialias=True, align_corners=False)
        x[m] = F.interpolate(small, size=(h, w), mode="bilinear", align_corners=False)
    m = torch.rand(n, device=dev) < ZOOMOUT_P
    if m.any():
        f = float(torch.empty(1).uniform_(0.5, 0.85))
        sh, sw = round(h * f), round(w * f)
        sel = x[m]
        canvas = sel.mean(dim=(2, 3), keepdim=True).expand(-1, -1, h, w).clone()
        top, left = (h - sh) // 2, (w - sw) // 2
        canvas[:, :, top:top + sh, left:left + sw] = F.interpolate(sel, size=(sh, sw), mode="bilinear",
                                                                   antialias=True, align_corners=False)
        x[m] = canvas
    return x.clamp_(0, 1)


def dist_info():
    """(rank, world, local_rank): torchrun ortam değişkenlerinden; tek süreçte (0, 1, 0)."""
    return int(E("RANK", "0")), int(E("WORLD_SIZE", "1")), int(E("LOCAL_RANK", "0"))


def device():
    import torch
    if not torch.cuda.is_available():
        return torch.device("cpu")
    return torch.device("cuda", dist_info()[2])


def auto_batch():
    import torch
    if BATCH:
        return BATCH
    if not torch.cuda.is_available():
        return 16
    gb = torch.cuda.get_device_properties(0).total_memory / 2**30
    b = 128 if gb > 35 else 64 if gb > 14 else 32  # 320 px için
    return max(16, int(b * (320 / IMG) ** 2 / 16 + 0.5) * 16)  # 384 px, 16 GB: 48


def build_model(n_classes, pretrained=True):
    import timm
    return timm.create_model(MODEL, pretrained=pretrained, num_classes=n_classes, drop_rate=0.3,
                             drop_path_rate=0.2)


def static_padding(model, img):
    """TF tarzı "same" dolgulu katmanları (Conv2dSame) sabit dolgu + normal Conv2d ile değiştirir.
    Girdi boyutu sabit olduğundan sonuç aynıdır; Core ML dönüştürücüsü dinamik dolguyu çeviremez."""
    import torch
    from timm.layers import Conv2dSame
    sizes, hooks = {}, []
    for name, m in model.named_modules():
        if isinstance(m, Conv2dSame):
            hooks.append(m.register_forward_pre_hook(lambda mod, inp, n=name: sizes.__setitem__(n, inp[0].shape[-2:])))
    with torch.no_grad():
        model(torch.zeros(1, 3, img, img))
    for h in hooks:
        h.remove()
    for name, (ih, iw) in sizes.items():
        m = model.get_submodule(name)
        pads = []
        for i, k, st, d in ((ih, m.kernel_size[0], m.stride[0], m.dilation[0]), (iw, m.kernel_size[1], m.stride[1], m.dilation[1])):
            pads.append(max((math.ceil(i / st) - 1) * st + (k - 1) * d + 1 - i, 0))
        ph, pw = pads
        conv = torch.nn.Conv2d(m.in_channels, m.out_channels, m.kernel_size, m.stride, 0, m.dilation, m.groups, m.bias is not None)
        conv.load_state_dict(m.state_dict())
        new = torch.nn.Sequential(torch.nn.ZeroPad2d((pw // 2, pw - pw // 2, ph // 2, ph - ph // 2)), conv)
        parent, _, leaf = name.rpartition(".")
        setattr(model.get_submodule(parent) if parent else model, leaf, new)
    return model


# ---------------------------------------------------------------- 1b. öğretmen (isteğe bağlı)

# Sunucudaki (tools/kus_sunucu) BioCLIP 2 metin biçimi: bilimsel + yaygın ad, şablonların ortalaması
SABLONLAR = (
    "a photo of {}.",
    "a photo of a {}.",
    "a close-up photo of a {}.",
    "a bad photo of a {}.",
    "a photo of the small {}.",
)


def cmd_ogretmen():
    """BioCLIP 2 sıfır-atış yumuşak etiketleri (bilgi damıtma için), bir kez hesaplanır → OGRETMEN.
    Eğitim ve doğrulama fotoğrafları ortadan kırpılmış 224 px ile bir kez geçer (T4'te ~15 dk).
    Öğretmenin doğrulama doğruluğu da kaydedilir; KD_MIN altındaysa eğitimde damıtma yapılmaz."""
    import open_clip
    import torch
    import torch.nn.functional as F
    from PIL import Image

    classes, items = dataset()
    labels = [c["label"] for c in classes]
    if os.path.exists(OGRETMEN):
        s = torch.load(OGRETMEN, map_location="cpu", weights_only=False)
        if s.get("classes") == labels and s.get("model") == BIOCLIP:
            log(f"Öğretmen etiketleri zaten var ({OGRETMEN}); doğrulama %{s['val_top1'] * 100:.1f}")
            return
    dev = device()
    model, _, pre = open_clip.create_model_and_transforms(BIOCLIP)
    tok = open_clip.get_tokenizer(BIOCLIP)
    model = model.to(dev).eval()
    amp = dict(device_type=dev.type, dtype=torch.float16, enabled=dev.type == "cuda")
    with torch.no_grad(), torch.autocast(**amp):
        txt = []
        for c in classes:
            ad = f"{c['sci']} with common name {c['en']}"
            e = model.encode_text(tok([t.format(ad) for t in SABLONLAR]).to(dev)).float()
            e = F.normalize(e, dim=-1).mean(0)
            txt.append(e / e.norm())
        txt = torch.stack(txt)
        scale = float(model.logit_scale.exp())

    class DS(torch.utils.data.Dataset):
        def __init__(self, rows):
            self.rows = rows

        def __len__(self):
            return len(self.rows)

        def __getitem__(self, i):
            with Image.open(self.rows[i][0]) as im:
                return pre(im.convert("RGB")), self.rows[i][1]

    def run(rows, name):
        dl = torch.utils.data.DataLoader(DS(rows), batch_size=128, num_workers=min(8, os.cpu_count() or 2),
                                         worker_init_fn=_one_thread)
        out, t0 = [], time.time()
        with torch.no_grad(), torch.autocast(**amp):
            for k, (x, _) in enumerate(dl):
                f = F.normalize(model.encode_image(x.to(dev, non_blocking=True)).float(), dim=-1)
                out.append((scale * f @ txt.T).half().cpu())
                if k % 100 == 0:
                    log(f"  öğretmen {name}: {k}/{len(dl)} · {k * 128 / max(1e-6, time.time() - t0):.0f} görüntü/sn")
        return torch.cat(out)

    yv = torch.tensor([c for _, c in items["val"]])
    lv = run(items["val"], "doğrulama").float()
    top1 = (lv.argmax(1) == yv).float().mean().item()
    top3 = (lv.topk(3, 1).indices == yv[:, None]).any(1).float().mean().item()
    log(f"BioCLIP 2 sıfır-atış doğrulama: ilk tahmin %{top1 * 100:.1f} · ilk 3 %{top3 * 100:.1f}")
    s = {"model": BIOCLIP, "classes": labels, "val_top1": top1, "val_top3": top3, "scale": scale}
    if top1 >= KD_MIN:
        s["logits"] = run(items["train"], "eğitim")
        s["rows"] = [os.path.relpath(p, FOTO) for p, _ in items["train"]]
    else:
        log(f"Öğretmen doğruluğu KD_MIN={KD_MIN} altında: eğitim etiketleri hesaplanmadı, damıtma yapılmayacak")
    os.makedirs(os.path.dirname(OGRETMEN) or ".", exist_ok=True)
    torch.save(s, OGRETMEN + ".tmp")
    os.replace(OGRETMEN + ".tmp", OGRETMEN)
    log(f"Öğretmen etiketleri: {OGRETMEN} ({os.path.getsize(OGRETMEN) / 1e6:.0f} MB)")


def load_teacher(classes, rows, dev, say):
    """Eğitim satırlarıyla aynı sırada öğretmen olasılıkları (softmax(logit / KD_T), GPU'da fp16) ya da None."""
    import torch
    if KD <= 0:
        say("Bilgi damıtma kapalı (KD=0)")
        return None
    if not os.path.exists(OGRETMEN):
        say(f"Bilgi damıtma kapalı: öğretmen dosyası yok ({OGRETMEN})")
        return None
    s = torch.load(OGRETMEN, map_location="cpu", weights_only=False)
    if s.get("classes") != [c["label"] for c in classes]:
        say("Bilgi damıtma kapalı: öğretmen dosyası farklı sınıf listesi için")
        return None
    if s.get("val_top1", 0) < KD_MIN or "logits" not in s:
        say(f"Bilgi damıtma kapalı: öğretmen doğruluğu %{s.get('val_top1', 0) * 100:.1f} < KD_MIN")
        return None
    pos = {r: i for i, r in enumerate(s["rows"])}
    rel = [os.path.relpath(p, FOTO) for p, _ in rows]
    miss = sum(r not in pos for r in rel)
    if miss:
        say(f"Bilgi damıtma kapalı: {miss} eğitim fotoğrafının öğretmen etiketi yok")
        return None
    logits = s["logits"][torch.tensor([pos[r] for r in rel])].float()
    say(f"Bilgi damıtma açık: BioCLIP 2 (doğrulama %{s['val_top1'] * 100:.1f}) · ağırlık {KD} · sıcaklık {KD_T}")
    return torch.softmax(logits / KD_T, 1).half().to(dev)


def _mix_lam(ys, y, n_classes, smoothing):
    """timm Mixup'ın bu gruba uyguladığı oran (lam), karıştırılmış hedeften geri hesaplanır
    (grup kipi: örnek i, i'nin ters sıradaki eşiyle karışır). Öğretmen olasılıkları aynı oranla karıştırılır."""
    off = smoothing / n_classes
    on = 1.0 - smoothing + off
    d = (y != y.flip(0)).nonzero()
    if not len(d):
        return 1.0
    j = int(d[0])
    return float((ys[j, y[j]] - off) / (on - off))


# ---------------------------------------------------------------- 2. eğit

def gpu_count():
    """GPUS ortam değişkeni (0/boş: görünen tüm GPU'lar)."""
    import torch
    n = torch.cuda.device_count() if torch.cuda.is_available() else 0
    return max(1, min(int(E("GPUS", "0") or 0) or n, n or 1))


def cmd_egit():
    import torch
    if "LOCAL_RANK" not in os.environ and gpu_count() > 1:
        # GPU başına bir süreç (DistributedDataParallel): torchrun ile kendini yeniden başlatır
        import subprocess
        cmd = [sys.executable, "-m", "torch.distributed.run", "--standalone", f"--nproc_per_node={gpu_count()}",
               os.path.abspath(__file__), "egit"]
        log("Çok GPU:", " ".join(cmd))
        sys.exit(subprocess.call(cmd))
    import torch.distributed as dist
    from timm.data import Mixup
    from timm.loss import SoftTargetCrossEntropy
    from timm.utils import ModelEmaV3

    rank, world, local = dist_info()
    main = rank == 0
    if world > 1:
        import datetime
        if torch.cuda.is_available():
            torch.cuda.set_device(local)
        # Doğrulama yalnızca 0. süreçte; diğerleri bekler (uzun sürebilir). gloo: GPU'suz deneme
        dist.init_process_group("nccl" if torch.cuda.is_available() else "gloo",
                                timeout=datetime.timedelta(minutes=60))
    say = log if main else (lambda *a: None)
    torch.manual_seed(1234 + rank)  # süreç başına farklı karıştırma/silme; ağırlıklar DDP ile 0. süreçten

    classes, items = dataset()
    C = len(classes)
    say(f"{C} sınıf · eğitim {len(items['train'])} · doğrulama {len(items['val'])} · test {len(items['test'])}")
    dev = device()
    batch = auto_batch()
    gbatch = batch * world
    lr = LR or 4e-4 * math.sqrt(gbatch / 64)  # öğrenme oranı toplam batch'e göre
    if dev.type == "cuda":
        say("GPU:", torch.cuda.get_device_name(dev), f"× {world} · batch {batch}×{world}={gbatch} · lr {lr:g} · "
            f"{EPOCHS} tur · {IMG}px")
    dl, _ = loaders(items, C, batch, rank=rank, world=world)
    model = build_model(C).to(dev).to(memory_format=torch.channels_last)
    teacher = load_teacher(classes, items["train"], dev, say)

    head = set(id(p) for p in model.get_classifier().parameters())
    decay, no_decay, head_p = [], [], []
    for p in model.parameters():
        (head_p if id(p) in head else no_decay if p.ndim <= 1 else decay).append(p)
    opt = torch.optim.AdamW([
        {"params": decay, "weight_decay": 0.05, "lr": lr},
        {"params": no_decay, "weight_decay": 0.0, "lr": lr},
        {"params": head_p, "weight_decay": 0.01, "lr": lr * 5},  # yeni sınıflandırıcı daha hızlı öğrenir
    ])
    base_lrs = [g["lr"] for g in opt.param_groups]
    steps_per_epoch = len(dl["train"])
    total, warm = EPOCHS * steps_per_epoch, steps_per_epoch
    smoothing = 0.1
    mixup = Mixup(mixup_alpha=0.2, cutmix_alpha=1.0, prob=0.6, switch_prob=0.5, label_smoothing=smoothing,
                  num_classes=C)
    crit = SoftTargetCrossEntropy()
    use_amp = dev.type == "cuda"
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)
    # EMA, doğrulama ve kayıt yalnızca 0. süreçte (DDP'de ağırlıklar tüm süreçlerde aynı)
    ema = ModelEmaV3(model, decay=0.9998, use_warmup=True) if main else None

    os.makedirs(YEDEK, exist_ok=True)
    ck = os.path.join(YEDEK, "kontrol.pt")
    start, best, history = 0, 0.0, []
    hiz = E("HIZ_DOSYA")  # hız denemesi: ölçümü yaz, doğrulama ve kayıt yok
    if os.path.exists(ck) and not hiz:
        s = torch.load(ck, map_location="cpu", weights_only=False)
        if s.get("classes") == [c["label"] for c in classes] and s.get("model_name") == MODEL and s.get("img", IMG) == IMG:
            model.load_state_dict(s["model"])
            if ema is not None:
                ema.module.load_state_dict(s["ema"])
            opt.load_state_dict(s["opt"]); scaler.load_state_dict(s["scaler"])
            start, best, history = s["epoch"] + 1, s["best"], s.get("history", [])
            say(f"Kontrol noktasından devam: tur {start + 1}")
        else:
            say("Eski kontrol noktası farklı sınıf listesi/model/boyut için; sıfırdan başlanıyor")
    net = model
    if world > 1:
        # Her süreçte ayrı autocast (DataParallel'deki kopya sorunu yok), gradyanlar all-reduce ile
        net = torch.nn.parallel.DistributedDataParallel(model, device_ids=[local] if dev.type == "cuda" else None,
                                                        gradient_as_bucket_view=True)

    for epoch in range(start, EPOCHS):
        net.train()
        if world > 1:
            dl["train"].sampler.set_epoch(epoch)
        mixup.mixup_enabled = epoch < EPOCHS - 2  # son 2 tur: karıştırmasız (gerçek görüntülere uyum)
        t0, seen, loss_sum = time.time(), 0, 0.0
        tw, sw, warm_steps = None, 0, min(10, max(1, (MAX_STEPS or steps_per_epoch) // 3))
        for i, (x, y, idx) in enumerate(dl["train"]):
            step = epoch * steps_per_epoch + i
            f = step / warm if step < warm else 0.5 * (1 + math.cos(math.pi * (step - warm) / max(1, total - warm)))
            for g, b in zip(opt.param_groups, base_lrs):
                g["lr"] = b * max(f, 0.002)
            x = gpu_prep(x, train=True)
            y = y.to(dev, non_blocking=True)
            x, ys = mixup(x, y)
            with torch.autocast(dev.type, dtype=torch.float16, enabled=use_amp):
                out = net(x)
                loss = crit(out, ys)
                if teacher is not None:
                    pt = teacher[idx.to(dev)].float()
                    lam = _mix_lam(ys, y, C, smoothing)
                    if lam < 1.0:
                        pt = lam * pt + (1 - lam) * pt.flip(0)
                    logp = torch.log_softmax(out.float() / KD_T, 1)
                    kd = (pt * (pt.clamp_min(1e-8).log() - logp)).sum(1).mean() * KD_T ** 2
                    loss = (1 - KD) * loss + KD * kd
            opt.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.unscale_(opt)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
            scaler.step(opt)
            scaler.update()
            if ema is not None:
                ema.update(model, step=step)
            seen += x.size(0); loss_sum += loss.item() * x.size(0)
            if i == warm_steps:
                tw, sw = time.time(), seen
            if MAX_STEPS and i >= MAX_STEPS:
                break
            if main and i % int(E("LOG_EVERY", "200")) == 0:
                log(f"  tur {epoch + 1}/{EPOCHS} adım {i}/{steps_per_epoch} kayıp {loss.item():.3f} "
                    f"{seen * world / (time.time() - t0):.0f} görüntü/sn · bellek {_rss_gb():.1f} GB "
                    f"(sistem {_mem_used_gb():.1f} GB, GPU {_gpu_gb(dev):.1f} GB)")
        t_end = time.time()
        if world > 1:
            t = torch.tensor([loss_sum, seen], device=dev, dtype=torch.float64)
            dist.all_reduce(t)
            loss_sum, seen = t.tolist()
        if hiz:
            if main:
                steady = (seen - sw * world) / (t_end - tw) if tw and t_end > tw else seen / (t_end - t0)
                r = {"gpus": world, "batch_per_gpu": batch, "img": IMG, "images_per_s": round(steady, 1),
                     "images_per_s_with_warmup": round(seen / (t_end - t0), 1), "rss_gb": round(_rss_gb(), 2),
                     "system_mem_used_gb": round(_mem_used_gb(), 2), "gpu_mem_gb": round(_gpu_gb(dev), 2),
                     "n_train": len(items["train"]), "steps": i + 1, "kd": teacher is not None}
                json.dump(r, open(hiz, "w"), indent=1)
                log("HIZ", json.dumps(r))
            break
        if main:
            acc_m = accuracy(model, dl["val"], dev)
            acc_e = accuracy(ema.module, dl["val"], dev)
            history.append({"epoch": epoch + 1, "loss": loss_sum / max(1, seen), "val": acc_m, "val_ema": acc_e,
                            "minutes": (time.time() - t0) / 60, "gpus": world, "kd": teacher is not None})
            log(f"TUR {epoch + 1}: kayıp {loss_sum / max(1, seen):.3f} · doğrulama %{acc_m * 100:.1f} · "
                f"EMA %{acc_e * 100:.1f} · {(time.time() - t0) / 60:.1f} dk")
            names = [c["label"] for c in classes]
            if max(acc_m, acc_e) >= best:
                best = max(acc_m, acc_e)
                torch.save({"weights": (ema.module if acc_e >= acc_m else model).state_dict(), "classes": classes,
                            "model_name": MODEL, "img": IMG, "val": best}, os.path.join(YEDEK, "en_iyi.pt"))
            state = {"model": model.state_dict(), "ema": ema.module.state_dict(), "opt": opt.state_dict(),
                     "scaler": scaler.state_dict(), "epoch": epoch, "best": best, "classes": names,
                     "model_name": MODEL, "img": IMG, "history": history}
            torch.save(state, ck + ".tmp"); os.replace(ck + ".tmp", ck)
        if world > 1:
            dist.barrier()
    if main and not hiz:
        json.dump(history, open(os.path.join(YEDEK, "egitim_gecmisi.json"), "w"), indent=1)
        log(f"Eğitim bitti. En iyi doğrulama doğruluğu %{best * 100:.1f}")
    if world > 1:
        dist.barrier()
        dist.destroy_process_group()


def _mem_used_gb():
    """Makinedeki toplam kullanılan bellek (tüm süreçler ve veri yükleyici işçileri dahil)."""
    try:
        m = dict(line.split(":", 1) for line in open("/proc/meminfo"))
        return (int(m["MemTotal"].split()[0]) - int(m["MemAvailable"].split()[0])) / 2**20
    except (OSError, KeyError, ValueError):
        return 0.0


def _gpu_gb(dev):
    import torch
    return torch.cuda.max_memory_allocated(dev) / 2**30 if dev.type == "cuda" else 0.0


def _rss_gb():
    """Ana sürecin en yüksek bellek kullanımı (Linux'ta KB)."""
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20


def predict(model, loader, dev):
    import torch
    model.eval()
    outs, ys = [], []
    with torch.no_grad(), torch.autocast(dev.type, dtype=torch.float16, enabled=dev.type == "cuda"):
        for x, y in loader:
            outs.append(model(gpu_prep(x, train=False)).float().cpu())
            ys.append(y)
    return torch.cat(outs), torch.cat(ys)


def accuracy(model, loader, dev):
    logits, y = predict(model, loader, dev)
    return (logits.argmax(1) == y).float().mean().item()


def load_best():
    import torch
    s = torch.load(os.path.join(YEDEK, "en_iyi.pt"), map_location="cpu", weights_only=False)
    global MODEL, IMG
    MODEL, IMG = s["model_name"], s["img"]
    m = build_model(len(s["classes"]), pretrained=False)
    m.load_state_dict(s["weights"])
    return m, s["classes"]


# ---------------------------------------------------------------- 3. değerlendir

def cmd_degerlendir():
    import torch
    model, classes = load_best()
    dev = device()
    model = model.to(dev).to(memory_format=torch.channels_last)
    _, items = dataset()
    dl, _ = loaders(items, len(classes), auto_batch(), train=False)
    val_logits, val_y = predict(model, dl["val"], dev)
    logits, y = predict(model, dl["test"], dev)

    # Sıcaklık ölçekleme: gösterilen yüzdeler gerçek isabet oranına yakın olsun
    logT = torch.zeros(1, requires_grad=True)
    o = torch.optim.LBFGS([logT], lr=0.1, max_iter=200)

    def closure():
        o.zero_grad()
        l = torch.nn.functional.cross_entropy(val_logits / logT.exp(), val_y)
        l.backward()
        return l
    o.step(closure)
    temp = float(logT.detach().exp())

    probs = torch.softmax(logits / temp, 1)
    conf, pred = probs.max(1)
    top3 = (probs.topk(min(3, probs.shape[1]), 1).indices == y[:, None]).any(1).float().mean().item()
    top1 = (pred == y).float().mean().item()

    def ece(p):
        c, pr = p.max(1)
        e = 0.0
        for lo in range(10):
            m = (c > lo / 10) & (c <= (lo + 1) / 10)
            if m.any():
                e += m.float().mean().item() * abs((pr[m] == y[m]).float().mean().item() - c[m].mean().item())
        return e

    hunt, prot = mak()
    sci = [c["sci"] for c in classes]
    is_hunt = torch.tensor([s in hunt for s in sci])
    # Av listesinde (MAK EK-2) olmayan her yabani kuş avlanamaz. En önemli güvenlik ölçüsü:
    # avlanamayan kuşun av türü sanılması. EK-1 (benzer türler) ayrıca raporlanır.
    is_prot = ~is_hunt
    is_ek1 = torch.tensor([s in prot for s in sci])
    pm = is_prot[y]
    danger = pm & is_hunt[pred]
    danger_hi = danger & (conf >= 0.7)
    per = []
    conf_pairs = Counter()
    for c in range(len(classes)):
        m = y == c
        n = int(m.sum())
        rec = (pred[m] == c).float().mean().item() if n else float("nan")
        wrong = Counter(pred[m][pred[m] != c].tolist()).most_common(1)
        per.append({"tur": classes[c]["tr"], "bilimsel": sci[c], "test": n, "dogru_orani": round(rec, 3),
                    "durum": "av" if sci[c] in hunt else "EK-1 koruma" if sci[c] in prot else "avlanamaz",
                    "en_cok_karistigi": classes[wrong[0][0]]["tr"] if wrong else ""})
    for t, p in zip(y.tolist(), pred.tolist()):
        if t != p and is_prot[t] and is_hunt[p]:
            conf_pairs[(classes[t]["tr"], classes[p]["tr"])] += 1

    metrics = {
        "model": MODEL, "img": IMG, "classes": len(classes), "temperature": round(temp, 3),
        "test_images": len(y), "top1": round(top1, 4), "top3": round(top3, 4),
        "macro_recall": round(float(sum(r["dogru_orani"] for r in per if r["test"]) / max(1, sum(1 for r in per if r["test"]))), 4),
        "ece_before": round(ece(torch.softmax(logits, 1)), 4), "ece_after": round(ece(probs), 4),
        "protected_test_images": int(pm.sum()),
        "ek1_as_game": round((is_ek1[y] & is_hunt[pred]).float().sum().item() / max(1, int(is_ek1[y].sum())), 4),
        "protected_as_game": round(danger.float().sum().item() / max(1, int(pm.sum())), 4),
        "protected_as_game_conf70": round(danger_hi.float().sum().item() / max(1, int(pm.sum())), 4),
        "top1_when_conf70": round(((pred == y) & (conf >= 0.7)).float().sum().item() / max(1, int((conf >= 0.7).sum())), 4),
        "share_conf70": round((conf >= 0.7).float().mean().item(), 4),
        "licenses": LICENSES, "date": time.strftime("%Y-%m-%d"),
    }
    os.makedirs(CIKTI, exist_ok=True)
    json.dump(metrics, open(os.path.join(CIKTI, "metrikler.json"), "w"), indent=1, ensure_ascii=False)
    with open(os.path.join(CIKTI, "tur_basari.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(per[0]))
        w.writeheader()
        w.writerows(sorted(per, key=lambda r: r["dogru_orani"] if r["test"] else 2))
    with open(os.path.join(CIKTI, "koruma_av_karisiklik.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["gercek_tur_avlanamaz", "tahmin_av_turu", "adet"])
        for (a, b), n in conf_pairs.most_common():
            w.writerow([a, b, n])
    log(json.dumps(metrics, indent=1, ensure_ascii=False))
    log("Kararlar: top1 ≥ 0.75 ve protected_as_game_conf70 ≤ 0.01 ise uygulamaya eklenir.")


# ---------------------------------------------------------------- 3b. performans

def quantize_int8_(model):
    """Core ML'deki int8 ağırlık sıkıştırmasının (linear_symmetric, kanal başına) PyTorch benzetimi.
    Böylece int8 doğruluk kaybı GPU'da, tam test kümesinde ölçülür."""
    import torch
    with torch.no_grad():
        for m in model.modules():
            if isinstance(m, (torch.nn.Conv2d, torch.nn.Linear)) and m.weight.numel() >= 2048:
                w = m.weight
                scale = w.abs().flatten(1).max(1).values.clamp(min=1e-12) / 127
                shape = (-1,) + (1,) * (w.ndim - 1)
                m.weight.copy_((w / scale.view(shape)).round().clamp(-127, 127) * scale.view(shape))
    return model


def cmd_performans():
    """Doğruluk dışındaki ölçümler (hepsi Colab'da): int8/fp16 doğruluk kaybı, zor koşullara
    dayanıklılık, hız, boyut ve işlem yükü. Sonuç: <cikti>/performans.json (+ metrikler.json'a özet)."""
    import copy
    import torch
    from PIL import Image, ImageFilter
    from torchvision import transforms as T

    model, classes = load_best()
    dev = device()
    _, items = dataset()
    rows = items["test"]
    batch = auto_batch()
    base = T.Compose([T.Resize(IMG, interpolation=T.InterpolationMode.BICUBIC), T.CenterCrop(IMG)])

    def jpeg(im, q):
        b = io.BytesIO()
        im.save(b, "JPEG", quality=q)
        return Image.open(io.BytesIO(b.getvalue())).convert("RGB")

    def far(im, f):  # uzaktaki kuş: küçült, gri kenarla doldur (kuş kadrajda küçük kalır)
        small = im.resize((max(1, im.width // f), max(1, im.height // f)), Image.BICUBIC)
        canvas = Image.new("RGB", im.size, (110, 110, 100))
        canvas.paste(small, ((im.width - small.width) // 2, (im.height - small.height) // 2))
        return canvas

    conditions = {
        "normal": lambda im: im,
        "bulanik": lambda im: im.filter(ImageFilter.GaussianBlur(2.5)),
        "karanlik": lambda im: im.point(lambda v: int(255 * (v / 255) ** 2.2 * 0.6)),
        "jpeg_dusuk": lambda im: jpeg(im, 25),
        "uzak_2x": lambda im: far(im, 2),
        "dusuk_cozunurluk": lambda im: im.resize((IMG // 3, IMG // 3), Image.BILINEAR).resize((IMG, IMG), Image.BICUBIC),
        "egik_20": lambda im: im.rotate(20, resample=Image.BICUBIC, fillcolor=(110, 110, 100)),
    }

    class DS(torch.utils.data.Dataset):
        def __init__(self, fn):
            self.fn = fn

        def __len__(self):
            return len(rows)

        def __getitem__(self, i):
            p, c = rows[i]
            with Image.open(p) as im:
                return T.functional.pil_to_tensor(self.fn(base(im.convert("RGB")))), c

    def run(m, fn):
        dl = torch.utils.data.DataLoader(DS(fn), batch_size=batch * 2, num_workers=min(8, os.cpu_count() or 2),
                                         worker_init_fn=_one_thread)
        logits, y = predict(m, dl, dev)
        return (logits.argmax(1) == y).float().mean().item(), logits

    m32 = model.to(dev).to(memory_format=torch.channels_last).eval()
    res = {"conditions": {}}
    hunt, _ = mak()
    is_hunt = torch.tensor([c["sci"] in hunt for c in classes])
    y_all = torch.tensor([c for _, c in rows])
    for name, fn in conditions.items():
        acc, logits = run(m32, fn)
        pred = logits.argmax(1)
        danger = (~is_hunt[y_all] & is_hunt[pred]).float().sum().item() / max(1, int((~is_hunt[y_all]).sum()))
        res["conditions"][name] = {"top1": round(acc, 4), "nongame_as_game": round(danger, 4)}
        log(f"  {name:18s} ilk tahmin %{acc * 100:.1f} · avlanamayanı av sanma %{danger * 100:.2f}")

    # Sıkıştırma kaybı: fp16 (Core ML varsayılanı) ve int8 ağırlıklar, tam test kümesinde
    m16 = copy.deepcopy(model).to(dev).half().float().eval()  # ağırlıklar fp16'ya yuvarlanır
    acc16, _ = run(m16, conditions["normal"])
    m8 = quantize_int8_(copy.deepcopy(model).cpu()).to(dev).to(memory_format=torch.channels_last).eval()
    acc8, _ = run(m8, conditions["normal"])
    res["precision"] = {"fp32": res["conditions"]["normal"]["top1"], "fp16": round(acc16, 4), "int8": round(acc8, 4),
                        "int8_loss_points": round((res["conditions"]["normal"]["top1"] - acc8) * 100, 2)}
    log(f"  hassasiyet: fp32 %{res['precision']['fp32'] * 100:.2f} · fp16 %{acc16 * 100:.2f} · int8 %{acc8 * 100:.2f}")

    # Verimlilik: parametre, işlem yükü, GPU toplu hız, CPU tek görüntü gecikmesi
    from torch.utils.flop_counter import FlopCounterMode
    cpu_model = copy.deepcopy(model).cpu().eval()
    x1 = torch.randn(1, 3, IMG, IMG)
    with torch.no_grad(), FlopCounterMode(display=False) as fc:
        cpu_model(x1)
    params = sum(p.numel() for p in cpu_model.parameters())
    with torch.no_grad():
        for _ in range(3):
            cpu_model(x1)
        t0 = time.time()
        for _ in range(10):
            cpu_model(x1)
        cpu_ms = (time.time() - t0) / 10 * 1000
    gpu_ips = None
    if dev.type == "cuda":
        xb = torch.randn(batch, 3, IMG, IMG, device=dev).to(memory_format=torch.channels_last)
        with torch.no_grad(), torch.autocast("cuda", dtype=torch.float16):
            for _ in range(3):
                m32(xb)
            torch.cuda.synchronize()
            t0 = time.time()
            for _ in range(10):
                m32(xb)
            torch.cuda.synchronize()
        gpu_ips = round(batch * 10 / (time.time() - t0))
    res["efficiency"] = {
        "params_millions": round(params / 1e6, 2), "gflops": round(fc.get_total_flops() / 2e9, 2),
        "size_fp16_mb": round(params * 2 / 1e6, 1), "size_int8_mb": round(params / 1e6, 1),
        "cpu_ms_per_image": round(cpu_ms, 1), "cpu_threads": torch.get_num_threads(), "gpu_images_per_s": gpu_ips,
        "note": "Colab CPU süresi yalnızca karşılaştırma içindir; iPhone'da model Neural Engine'de çalışır.",
    }
    log("  verimlilik:", json.dumps(res["efficiency"], ensure_ascii=False))

    os.makedirs(CIKTI, exist_ok=True)
    json.dump(res, open(os.path.join(CIKTI, "performans.json"), "w"), indent=1, ensure_ascii=False)
    mp = os.path.join(CIKTI, "metrikler.json")
    if os.path.exists(mp):
        m = json.load(open(mp))
        m["int8_top1"] = res["precision"]["int8"]
        m["robust_min_top1"] = min(v["top1"] for v in res["conditions"].values())
        m["robust_max_nongame_as_game"] = max(v["nongame_as_game"] for v in res["conditions"].values())
        json.dump(m, open(mp, "w"), indent=1, ensure_ascii=False)
    ok = res["precision"]["int8_loss_points"] <= 1.0
    log("int8 kaybı ≤ 1 puan: " + ("evet, int8 model kullanılacak" if ok else "HAYIR, fp16 model kullanılmalı"))


# ---------------------------------------------------------------- 4. Core ML

def cmd_aktar():
    import coremltools as ct
    import numpy as np
    import torch
    from PIL import Image

    model, classes = load_best()
    model.eval()
    ref = torch.randn(2, 3, IMG, IMG)
    with torch.no_grad():
        before = model(ref)
        model = static_padding(model, IMG)
        diff = (model(ref) - before).abs().max().item()
    assert diff < 1e-3, f"sabit dolgu çıktıyı değiştirdi ({diff})"
    metrics = json.load(open(os.path.join(CIKTI, "metrikler.json")))
    temp = metrics["temperature"]

    class Wrapper(torch.nn.Module):
        """Girdi 0–1 RGB; normalleştirme, sıcaklık ve softmax modelin içinde."""

        def __init__(self, m):
            super().__init__()
            self.m = m
            self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

        def forward(self, x):
            return torch.softmax(self.m((x - self.mean) / self.std) / temp, dim=1)

    w = Wrapper(model).eval()
    ex = torch.rand(1, 3, IMG, IMG)
    traced = torch.jit.trace(w, ex)
    labels = [c["label"] for c in classes]
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=ex.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        classifier_config=ct.ClassifierConfig(labels, predicted_feature_name="classLabel"),
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    spec = ml.get_spec()
    prob_name = [o.name for o in spec.description.output if o.name != "classLabel"][0]
    if prob_name != "classLabelProbs":
        ct.utils.rename_feature(spec, prob_name, "classLabelProbs")
        ml = ct.models.MLModel(spec, weights_dir=ml.weights_dir)
    ml.author = "Av Haritası (tools/kus_foto)"
    ml.license = "Eğitim verisi: iNaturalist (" + metrics["licenses"] + "); künye: kunye.csv"
    ml.short_description = (f"İstanbul kuşları ({len(labels)} tür) — fotoğraftan tür tahmini. "
                            f"Test doğruluğu %{metrics['top1'] * 100:.1f} (ilk 3: %{metrics['top3'] * 100:.1f}).")
    ml.version = metrics["date"]
    ml.user_defined_metadata["metrics"] = json.dumps(metrics)
    ml.input_description["image"] = f"Kuş fotoğrafı ({IMG}×{IMG}, ortadan kırpılmış)"

    for p in ("BirdClassifier.mlpackage", "BirdClassifier_fp16.mlpackage"):
        shutil.rmtree(os.path.join(CIKTI, p), ignore_errors=True)
    ml.save(os.path.join(CIKTI, "BirdClassifier_fp16.mlpackage"))
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
    q = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))
    q.save(os.path.join(CIKTI, "BirdClassifier.mlpackage"))

    # Doğrulama örnekleri: macOS'ta Core ML çıktısının PyTorch ile aynı olduğu CI'da denetlenir
    _, items = dataset()
    rows = items["test"][:: max(1, len(items["test"]) // 200)][:200]
    vd = os.path.join(CIKTI, "dogrulama")
    shutil.rmtree(vd, ignore_errors=True)
    os.makedirs(vd)
    expect = {}
    for i, (p, c) in enumerate(rows):
        with Image.open(p) as im:
            im = im.convert("RGB")
            s = IMG / min(im.size)
            im = im.resize((max(IMG, round(im.width * s)), max(IMG, round(im.height * s))), Image.BICUBIC)
            l, t = (im.width - IMG) // 2, (im.height - IMG) // 2
            im = im.crop((l, t, l + IMG, t + IMG))
            name = f"{i:03d}.png"
            im.save(os.path.join(vd, name))
        x = torch.from_numpy(np.asarray(Image.open(os.path.join(vd, name)), dtype=np.float32) / 255).permute(2, 0, 1)[None]
        with torch.no_grad():
            pr = w(x)[0]
        k = int(pr.argmax())
        expect[name] = {"true": labels[c], "torch": labels[k], "p": round(float(pr[k]), 4)}
    json.dump(expect, open(os.path.join(vd, "beklenen.json"), "w"), indent=1, ensure_ascii=False)

    json.dump(classes, open(os.path.join(CIKTI, "siniflar.json"), "w"), ensure_ascii=False, indent=1)
    write_credits(classes)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(os.path.join(CIKTI, "BirdClassifier.mlpackage")) for f in fs)
    log(f"Core ML hazır: BirdClassifier.mlpackage ({size / 1e6:.1f} MB, int8) ve _fp16 sürümü → {CIKTI}")


def write_credits(classes):
    labs = {c["sci"]: c["label"] for c in classes}
    with open(os.path.join(CIKTI, "kunye.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["sinif", "fotograf", "sahip", "lisans", "gozlem"])
        for sci, lab in labs.items():
            mp = os.path.join(META, sci.replace(" ", "_") + ".json")
            folder = os.path.join(FOTO, lab)
            if not os.path.exists(mp):
                continue
            for p in json.load(open(mp))["photos"]:
                if os.path.exists(os.path.join(folder, f"{p['id']}.jpg")):
                    w.writerow([lab, p["id"], p["user"], p["lic"], f"https://www.inaturalist.org/observations/{p['obs']}"])


# ---------------------------------------------------------------- 5. yükle

def cmd_yukle():
    import requests
    zp = os.path.join(YEDEK, "BirdClassifier_paket.zip")
    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        for d, _, fs in os.walk(CIKTI):
            for f in fs:
                full = os.path.join(d, f)
                z.write(full, os.path.relpath(full, CIKTI))
    for f in ("egitim_gecmisi.json",):
        if os.path.exists(os.path.join(YEDEK, f)):
            with zipfile.ZipFile(zp, "a") as z:
                z.write(os.path.join(YEDEK, f), f)
    log(f"Paket: {zp} ({os.path.getsize(zp) / 1e6:.1f} MB)")
    token = E("GH_TOKEN")
    if not token:
        log("GH_TOKEN yok: paketi Drive'dan indirip bana iletin (ya da Colab gizli anahtarı ekleyin).")
        return
    h = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    tag = "kus-foto-" + time.strftime("%Y%m%d-%H%M")
    m = json.load(open(os.path.join(CIKTI, "metrikler.json")))
    body = (f"Kuş fotoğrafı modeli ({m['classes']} tür, {m['model']}, {m['img']} px).\n\n"
            f"Test: ilk tahmin %{m['top1'] * 100:.1f}, ilk 3 %{m['top3'] * 100:.1f}. "
            f"Avlanamayan kuşun av türü sanılması: %{m['protected_as_game'] * 100:.2f} "
            f"(≥%70 güvenle: %{m['protected_as_game_conf70'] * 100:.2f}).")
    r = requests.post(f"https://api.github.com/repos/{SURUM_DEPO}/releases", headers=h,
                      json={"tag_name": tag, "name": tag, "body": body, "prerelease": True})
    if not r.ok:
        log(f"GitHub sürümü oluşturulamadı ({r.status_code}: {r.text[:200]}). Token'ın {SURUM_DEPO} için "
            f"'Contents: Read and write' izni olmalı. Paket Drive'da: {zp}")
        return
    up = r.json()["upload_url"].split("{")[0]
    with open(zp, "rb") as f:
        r = requests.post(up, headers={**h, "Content-Type": "application/zip"}, params={"name": "BirdClassifier_paket.zip"}, data=f)
    r.raise_for_status()
    log("Yüklendi:", r.json()["browser_download_url"])


if __name__ == "__main__":
    cmds = {"indir": cmd_indir, "ogretmen": cmd_ogretmen, "egit": cmd_egit, "degerlendir": cmd_degerlendir, "performans": cmd_performans, "aktar": cmd_aktar, "yukle": cmd_yukle}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(__doc__)
        sys.exit(2)
    cmds[sys.argv[1]]()
