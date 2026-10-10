#!/usr/bin/env python3
"""macOS'ta Core ML modelini PyTorch çıktısıyla karşılaştırır (Colab'da Core ML çalıştırılamaz).

  python dogrula.py <paket klasörü>

Paketteki dogrulama/*.png için BirdClassifier.mlpackage (int8) ve _fp16 sürümünün ilk tahmini,
PyTorch'un beklenen.json'daki tahminiyle karşılaştırılır. int8 en az %97 uyuşursa o seçilir,
yoksa fp16 (en az %99). Seçilen model <paket>/secilen/BirdClassifier.mlpackage olarak kopyalanır.
"""
import json
import os
import shutil
import sys

import coremltools as ct
from PIL import Image

root = sys.argv[1]
vd = os.path.join(root, "dogrulama")
expect = json.load(open(os.path.join(vd, "beklenen.json")))
metrics = json.load(open(os.path.join(root, "metrikler.json")))
# Colab'daki performans adımı int8 kaybını tam test kümesinde ölçer; 1 puandan fazlaysa int8 kullanılmaz
int8_ok = metrics["top1"] - metrics.get("int8_top1", metrics["top1"]) <= 0.01
report = {}
for name, need in (("BirdClassifier", 0.97), ("BirdClassifier_fp16", 0.99)):
    if name == "BirdClassifier" and not int8_ok:
        print("int8 atlandı: Colab ölçümünde doğruluk kaybı 1 puandan fazla")
        continue
    m = ct.models.MLModel(os.path.join(root, name + ".mlpackage"))
    same = true = 0
    for f, e in expect.items():
        out = m.predict({"image": Image.open(os.path.join(vd, f)).convert("RGB")})
        same += out["classLabel"] == e["torch"]
        true += out["classLabel"] == e["true"]
    report[name] = {"agreement": same / len(expect), "top1_sample": true / len(expect), "required": need}
    print(name, report[name], flush=True)
pick = next((n for n, r in report.items() if r["agreement"] >= r["required"]), None)
json.dump({"models": report, "selected": pick}, open(os.path.join(root, "dogrulama_raporu.json"), "w"), indent=1)
if not pick:
    sys.exit("Core ML çıktısı PyTorch ile uyuşmuyor; model kullanılamaz")
dst = os.path.join(root, "secilen")
shutil.rmtree(dst, ignore_errors=True)
os.makedirs(dst)
shutil.copytree(os.path.join(root, pick + ".mlpackage"), os.path.join(dst, "BirdClassifier.mlpackage"))
print("seçilen:", pick)
