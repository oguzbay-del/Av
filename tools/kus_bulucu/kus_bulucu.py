#!/usr/bin/env python3
"""Kuş bulucu (nesne algılama) modeli: YOLOX'u Core ML'e çevirir.

Fotoğraftaki kuşların kutularını bulur; tür modeli (BirdClassifier) bu kutulardan kırpılan görüntüde
çalışır. Model: Megvii YOLOX-S, COCO ağırlıkları (Apache-2.0). Ultralytics YOLO (AGPL) KULLANILMAZ.

  python kus_bulucu.py indir    YOLOX kaynak kodu (sabit sürüm) + resmi ağırlıklar → <is>/
  python kus_bulucu.py aktar    Core ML (int8 ağırlık, 640×640)  → <is>/BirdDetector.mlpackage
  python kus_bulucu.py ornek    ornekler/*.jpg için PyTorch kutuları → ornekler/beklenen.json
  python kus_bulucu.py hepsi    üçü birden; sonra paketi ios/AvHaritasi/BirdPhoto/ altına kopyalayın

Dönüştürme Linux'ta da çalışır (Core ML ile tahmin yalnızca macOS'ta): sonuç `dogrula.py` ile
macOS'ta denetlenir (.github/workflows/kus-bulucu-dogrula.yml).

Model arayüzü (Swift tarafı: CoreMLBirdDetector + DetectionDecoder):
  girdi  `image`  640×640 renkli görüntü, BGR, 0–255 (normalleştirme yok). Görüntü en-boy oranı korunarak
                  sol üst köşeye ölçeklenir, kalan alan gri (114) doldurulur (YOLOX "letterbox").
  çıktı  `boxes`  [100, 4] — cx, cy, w, h; 640'lık kare girdiye göre 0–1
         `scores` [100]    — kuş puanı = nesne olasılığı × COCO "bird" (14) sınıf olasılığı, büyükten küçüğe
  Eşik ve örtüşme bastırma (NMS) Swift'te yapılır.

Gereken paketler (CPU yeterli): torch torchvision coremltools numpy pillow opencv-python-headless loguru
tabulate thop psutil. Ortam: IS (çalışma klasörü, varsayılan ./is).
"""
import hashlib
import json
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
IS = os.environ.get("IS", os.path.join(HERE, "is"))
YOLOX_REPO = "https://github.com/Megvii-BaseDetection/YOLOX.git"
YOLOX_COMMIT = "6ddff4824372906469a7fae2dc3206c7aa4bbaee"  # 2025-06-08
WEIGHTS = {
    # ad: (url, sha256, derinlik, genişlik)
    "yolox_s": ("https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_s.pth",
                "f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30", 0.33, 0.50),
    "yolox_tiny": ("https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_tiny.pth",
                   "9de513de589ac98bb92d3bca53b5af7b9acfa9b0bacb831f7999d0f7afaee8f0", 0.33, 0.375),
}
MODEL = os.environ.get("MODEL", "yolox_s")
SIZE = int(os.environ.get("SIZE", "640"))
TOPK = 100
BIRD = 14  # COCO sınıf sırası: 0 person ... 14 bird
ORNEK = os.path.join(HERE, "ornekler")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def indir():
    os.makedirs(IS, exist_ok=True)
    src = os.path.join(IS, "YOLOX")
    if not os.path.isdir(src):
        subprocess.check_call(["git", "clone", "-q", YOLOX_REPO, src])
    subprocess.check_call(["git", "-C", src, "checkout", "-q", YOLOX_COMMIT])
    url, digest, _, _ = WEIGHTS[MODEL]
    dst = os.path.join(IS, MODEL + ".pth")
    if not os.path.exists(dst) or sha256(dst) != digest:
        urllib.request.urlretrieve(url, dst)
    if sha256(dst) != digest:
        sys.exit(f"{dst}: sha256 uyuşmuyor")
    print("indirildi:", src, dst)


def build():
    """Resmi YOLOX modelini kurar ve kuş çıkışlı sarmalayıcıyla döndürür."""
    import torch
    from torch import nn

    sys.path.insert(0, os.path.join(IS, "YOLOX"))
    from yolox.models import YOLOPAFPN, YOLOX, YOLOXHead

    _, _, depth, width = WEIGHTS[MODEL]
    inch = [256, 512, 1024]
    model = YOLOX(YOLOPAFPN(depth, width, in_channels=inch, act="silu"),
                  YOLOXHead(80, width, in_channels=inch, act="silu"))
    ckpt = torch.load(os.path.join(IS, MODEL + ".pth"), map_location="cpu", weights_only=False)
    model.load_state_dict(ckpt["model"])
    model.eval()
    model.head.decode_in_inference = True

    class BirdOnly(nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            out = self.m(x)[0]  # [N, 85]: cx, cy, w, h (piksel), nesne, 80 sınıf
            score = out[:, 4] * out[:, 5 + BIRD]
            top, idx = torch.topk(score, TOPK)
            boxes = out[idx, :4] / SIZE
            return boxes, top

    return BirdOnly(model).eval()


def aktar():
    import coremltools as ct
    import torch

    model = build()
    example = torch.rand(1, 3, SIZE, SIZE) * 255
    traced = torch.jit.trace(model, example)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), color_layout=ct.colorlayout.BGR,
                             scale=1.0, bias=[0, 0, 0])],
        outputs=[ct.TensorType(name="boxes"), ct.TensorType(name="scores")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )
    fp16 = os.path.join(IS, "BirdDetector_fp16.mlpackage")
    ml.save(fp16)
    cfg = ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048))
    q = ct.optimize.coreml.linear_quantize_weights(ml, cfg)
    q.author = "Megvii YOLOX (Apache-2.0), Av Haritası dönüştürmesi"
    q.license = "Apache-2.0"
    q.short_description = (f"{MODEL} COCO, yalnızca kuş (sınıf {BIRD}); girdi {SIZE}×{SIZE} BGR letterbox, "
                           f"çıktı en iyi {TOPK} kutu (cx, cy, w, h 0–1) ve kuş puanı")
    q.input_description["image"] = f"{SIZE}×{SIZE} BGR, sol üst hizalı letterbox, dolgu 114"
    q.output_description["boxes"] = "cx, cy, w, h (kare girdiye göre 0–1)"
    q.output_description["scores"] = "kuş puanı (nesne × kuş sınıfı), büyükten küçüğe"
    out = os.path.join(IS, "BirdDetector.mlpackage")
    q.save(out)
    for p in (fp16, out):
        size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(p) for f in fs)
        print(f"{p}: {size / 1e6:.1f} MB")


def ornek():
    """Örnek fotoğraflarda PyTorch'un bulduğu kuş kutuları (macOS'ta Core ML ile karşılaştırılır)."""
    import numpy as np
    import torch
    from PIL import Image

    sys.path.insert(0, HERE)
    from ortak import letterbox, nms

    model = build()
    expect = {}
    for f in sorted(os.listdir(ORNEK)):
        if not f.lower().endswith((".jpg", ".jpeg", ".png")):
            continue
        img = Image.open(os.path.join(ORNEK, f))
        canvas, _ = letterbox(img, SIZE)
        bgr = np.asarray(canvas)[:, :, ::-1].copy()
        x = torch.from_numpy(bgr).permute(2, 0, 1).float()[None]
        with torch.no_grad():
            boxes, scores = model(x)
        keep = nms(boxes.numpy(), scores.numpy())
        expect[f] = {"size": [img.width, img.height], "boxes": [b for b, _ in keep], "scores": [s for _, s in keep]}
        print(f, [round(s, 3) for _, s in keep])
    with open(os.path.join(ORNEK, "beklenen.json"), "w") as fh:
        json.dump({"model": MODEL, "size": SIZE, "images": expect}, fh, indent=1)


if __name__ == "__main__":
    steps = {"indir": [indir], "aktar": [aktar], "ornek": [ornek], "hepsi": [indir, aktar, ornek]}
    if len(sys.argv) != 2 or sys.argv[1] not in steps:
        sys.exit(__doc__)
    for step in steps[sys.argv[1]]:
        step()
