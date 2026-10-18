#!/usr/bin/env python3
"""macOS'ta kuş bulucu Core ML modelini denetler (Linux'ta Core ML tahmini çalışmaz).

  python dogrula.py [model.mlpackage]   (varsayılan: ios/AvHaritasi/BirdPhoto/BirdDetector.mlpackage)

ornekler/*.jpg (CC0, iNaturalist) her birinde en az bir kuş bulunmalı ve en iyi kutu PyTorch'un
kutusuyla (ornekler/beklenen.json, `kus_bulucu.py ornek`) örtüşmeli (IoU ≥ 0,7, puan farkı ≤ 0,1).
Düz gri görüntüde kuş bulunmamalı. Sonuç stdout ve çıkış koduyla verilir.
"""
import json
import os
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ortak import SIZE, THRESHOLD, iou, letterbox, nms  # noqa: E402

root = os.path.dirname(os.path.dirname(HERE))
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "ios/AvHaritasi/BirdPhoto/BirdDetector.mlpackage")
model = ct.models.MLModel(path)
with open(os.path.join(HERE, "ornekler", "beklenen.json")) as fh:
    expect = json.load(fh)
assert expect["size"] == SIZE

failures = []
times = []
for f, e in sorted(expect["images"].items()):
    img = Image.open(os.path.join(HERE, "ornekler", f))
    canvas, _ = letterbox(img)
    t = time.time()
    out = model.predict({"image": canvas})
    times.append(time.time() - t)
    kept = nms(np.asarray(out["boxes"]).reshape(-1, 4), np.asarray(out["scores"]).reshape(-1))
    best_iou = iou(kept[0][0], e["boxes"][0]) if kept and e["boxes"] else 0.0
    diff = abs(kept[0][1] - e["scores"][0]) if kept and e["scores"] else 1.0
    print(f, {"coreml": [round(s, 3) for _, s in kept], "torch": [round(s, 3) for s in e["scores"]],
              "top_iou": round(best_iou, 3), "top_score_diff": round(diff, 3)}, flush=True)
    if not kept:
        failures.append(f"{f}: kuş bulunamadı")
    elif best_iou < 0.7 or diff > 0.1:
        failures.append(f"{f}: PyTorch ile uyuşmuyor (IoU {best_iou:.2f}, puan farkı {diff:.2f})")

gray = Image.new("RGB", (800, 600), (128, 128, 128))
out = model.predict({"image": letterbox(gray)[0]})
gray_max = float(np.max(out["scores"]))
print("düz gri görüntü, en yüksek kuş puanı:", round(gray_max, 3))
if gray_max >= THRESHOLD:
    failures.append(f"düz gri görüntüde kuş bulundu ({gray_max:.2f})")

spec = model.get_spec()
print("girdi:", [i.name for i in spec.description.input], "çıktı:", [o.name for o in spec.description.output])
print(f"ortalama tahmin süresi (macOS, ilk hariç): {np.mean(times[1:]) * 1000:.0f} ms")
if failures:
    sys.exit("BAŞARISIZ:\n  " + "\n  ".join(failures))
print("TAMAM: tüm örneklerde kuş bulundu ve PyTorch ile uyuştu")
