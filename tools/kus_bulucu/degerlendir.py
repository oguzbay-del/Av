#!/usr/bin/env python3
"""Kuş bulucu ölçümü (PyTorch, GPU varsa GPU): eski (COCO, sınıf 14) ve ince ayarlı (tek sınıf) YOLOX-S.

  python degerlendir.py VERI CIKTI.json ad=agirlik.pth [ad=agirlik.pth ...]

Ön işleme uygulamadakiyle aynıdır (ortak.letterbox: sol üst hizalı 640 letterbox, gri 114, BGR 0–255);
puan = nesne × kuş sınıfı, örtüşme bastırma IoU 0,45 (DetectionDecoder), görüntü başına en çok 100 kutu.
Kümeler (veri.py): oi_test (Open Images val+test), coco_val (COCO val2017 kuşlu), coco_neg (COCO val2017 kuşsuz).

Ölçütler (kuş sınıfı): AP50:95, AP50, AP_small (alan < 32²), AP_medium, AP_<96² (alan < 96²), pycocotools ile;
uygulama eşiğinde (0,3) duyarlılık (IoU ≥ 0,5; tüm / küçük / < 96²) ve kesinlik; kuşsuz görüntülerde en az bir
≥ 0,3 kutu çıkan görüntü oranı (yanlış alarm). `esikler`: aynı ölçütler 0,2–0,7 eşiklerinde (eşit yanlış alarmda
duyarlılık karşılaştırması için).
"""
import json
import os
import sys

import numpy as np
import torch
import torchvision
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ortak import PAD, SIZE, letterbox  # noqa: E402

ESIK = 0.3  # uygulamadaki DetectionDecoder.defaultThreshold
ESIKLER = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6, 0.7]  # esikler[e] içinde "@0.3" adları e eşiğindeki değerdir
IOU_NMS = 0.45
KUMELER = ["oi_test", "coco_val", "coco_neg"]
ALAN = [[0, 1e10], [0, 32 ** 2], [32 ** 2, 96 ** 2], [96 ** 2, 1e10], [0, 96 ** 2]]
ALAN_AD = ["all", "small", "medium", "large", "lt96"]


def model_yukle(yol):
    from yolox.models import YOLOPAFPN, YOLOX, YOLOXHead

    sd = torch.load(yol, map_location="cpu", weights_only=False)["model"]
    nc = sd["head.cls_preds.0.weight"].shape[0]
    inch = [256, 512, 1024]
    m = YOLOX(YOLOPAFPN(0.33, 0.50, in_channels=inch, act="silu"), YOLOXHead(nc, 0.50, in_channels=inch, act="silu"))
    m.load_state_dict(sd)
    m.eval()
    m.head.decode_in_inference = True
    return m, (14 if nc == 80 else 0)


class Kume(torch.utils.data.Dataset):
    def __init__(self, veri, ad):
        self.veri = veri
        self.d = json.load(open(os.path.join(veri, "annotations", ad + ".json")))
        self.images = self.d["images"]

    def __len__(self):
        return len(self.images)

    def __getitem__(self, i):
        im = self.images[i]
        img = Image.open(os.path.join(self.veri, "images", im["file_name"]))
        canvas, r = letterbox(img, SIZE)
        bgr = np.asarray(canvas)[:, :, ::-1].copy()
        return torch.from_numpy(bgr).permute(2, 0, 1).float(), r, im["id"]


@torch.no_grad()
def tahmin(model, kus, kume, aygit):
    dl = torch.utils.data.DataLoader(kume, batch_size=32, num_workers=4)
    sonuc = []
    for x, r, ids in dl:
        out = model(x.to(aygit))
        for o, ri, iid in zip(out, r.tolist(), ids.tolist()):
            s = o[:, 4] * o[:, 5 + kus]
            k = s > 0.001
            o, s = o[k], s[k]
            xyxy = torch.stack([o[:, 0] - o[:, 2] / 2, o[:, 1] - o[:, 3] / 2,
                                o[:, 0] + o[:, 2] / 2, o[:, 1] + o[:, 3] / 2], 1)
            keep = torchvision.ops.nms(xyxy, s, IOU_NMS)[:100]
            for b, sc in zip((xyxy[keep] / ri).tolist(), s[keep].tolist()):
                sonuc.append({"image_id": iid, "category_id": 1, "bbox": [b[0], b[1], b[2] - b[0], b[3] - b[1]],
                              "score": sc})
    return sonuc


def ap_olc(gt_json, dets):
    from pycocotools.coco import COCO
    from pycocotools.cocoeval import COCOeval

    gt = COCO(gt_json)
    if not dets:
        return {}
    dt = gt.loadRes(dets)
    E = COCOeval(gt, dt, "bbox")
    E.params.areaRng = ALAN
    E.params.areaRngLbl = ALAN_AD
    E.evaluate()
    E.accumulate()
    p = E.eval["precision"]  # [T, R, K, A, M]

    def ap(t, a):
        v = p[t, :, 0, a, -1] if t is not None else p[:, :, 0, a, -1]
        v = v[v > -1]
        return round(float(v.mean()), 4) if v.size else None

    return {"AP50_95": ap(None, 0), "AP50": ap(0, 0), "AP75": ap(5, 0), "AP_small": ap(None, 1),
            "AP50_small": ap(0, 1), "AP_medium": ap(None, 2), "AP_large": ap(None, 3), "AP_lt96": ap(None, 4),
            "AP50_lt96": ap(0, 4)}


def iou(a, b):
    ax1, ay1, bx1, by1 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    iw, ih = max(0.0, min(ax1, bx1) - max(a[0], b[0])), max(0.0, min(ay1, by1) - max(a[1], b[1]))
    inter = iw * ih
    u = a[2] * a[3] + b[2] * b[3] - inter
    return inter / u if u > 0 else 0.0


def esik_olc(d, dets, esik=ESIK):
    """Uygulama eşiğinde açgözlü eşleme (IoU ≥ 0,5); kalabalık (iscrowd) kutuya düşen tahmin sayılmaz."""
    gt = {}
    for a in d["annotations"]:
        gt.setdefault(a["image_id"], []).append(a)
    dt = {}
    for x in dets:
        if x["score"] >= esik:
            dt.setdefault(x["image_id"], []).append(x)
    n = {"gt": 0, "gt_small": 0, "gt_lt96": 0, "tp": 0, "tp_small": 0, "tp_lt96": 0, "det": 0, "fp": 0}
    alarm = 0
    for im in d["images"]:
        g = [a for a in gt.get(im["id"], []) if not a["iscrowd"]]
        c = [a for a in gt.get(im["id"], []) if a["iscrowd"]]
        ds = sorted(dt.get(im["id"], []), key=lambda x: -x["score"])
        if ds:
            alarm += 1
        n["gt"] += len(g)
        n["gt_small"] += sum(a["area"] < 32 ** 2 for a in g)
        n["gt_lt96"] += sum(a["area"] < 96 ** 2 for a in g)
        used = set()
        for x in ds:
            best, bi = 0.5, None
            for i, a in enumerate(g):
                if i not in used:
                    v = iou(x["bbox"], a["bbox"])
                    if v >= best:
                        best, bi = v, i
            if bi is not None:
                used.add(bi)
                a = g[bi]
                n["tp"] += 1
                n["tp_small"] += a["area"] < 32 ** 2
                n["tp_lt96"] += a["area"] < 96 ** 2
                n["det"] += 1
            elif any(iou(x["bbox"], a["bbox"]) >= 0.5 for a in c):
                continue
            else:
                n["det"] += 1
                n["fp"] += 1

    def oran(a, b):
        return round(a / b, 4) if b else None

    return {"recall@0.3": oran(n["tp"], n["gt"]), "recall_small@0.3": oran(n["tp_small"], n["gt_small"]),
            "recall_lt96@0.3": oran(n["tp_lt96"], n["gt_lt96"]), "precision@0.3": oran(n["tp"], n["det"]),
            "images_with_bird@0.3": oran(alarm, len(d["images"])),
            "fp_boxes_per_image@0.3": oran(n["fp"], len(d["images"])),
            "n_images": len(d["images"]), "n_boxes": n["gt"], "n_small": n["gt_small"], "n_lt96": n["gt_lt96"]}


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    veri, cikti = sys.argv[1], sys.argv[2]
    aygit = "cuda" if torch.cuda.is_available() else "cpu"
    sonuc = {}
    for arg in sys.argv[3:]:
        ad, yol = arg.split("=", 1)
        model, kus = model_yukle(yol)
        model.to(aygit)
        sonuc[ad] = {}
        for k in KUMELER:
            j = os.path.join(veri, "annotations", k + ".json")
            if not os.path.exists(j):
                continue
            kume = Kume(veri, k)
            dets = tahmin(model, kus, kume, aygit)
            m = esik_olc(kume.d, dets)
            # eşik taraması: eski ve yeni modeli aynı yanlış alarm oranında karşılaştırmak için
            m["esikler"] = {}
            for e in ESIKLER:
                x = esik_olc(kume.d, dets, e)
                m["esikler"][str(e)] = {a: x[a] for a in ("recall@0.3", "recall_small@0.3", "precision@0.3",
                                                          "images_with_bird@0.3")}
            if k != "coco_neg":
                m.update(ap_olc(j, dets))
            sonuc[ad][k] = m
            print(ad, k, json.dumps(m), flush=True)
    json.dump(sonuc, open(cikti, "w"), indent=1)
    anahtar = ["AP50_95", "AP50", "AP_small", "AP50_small", "AP_lt96", "recall@0.3", "recall_small@0.3",
               "precision@0.3", "images_with_bird@0.3"]
    print("\n| küme | ölçüt | " + " | ".join(sonuc) + " |")
    for k in KUMELER:
        for a in anahtar:
            v = [sonuc[m].get(k, {}).get(a) for m in sonuc]
            if any(x is not None for x in v):
                print(f"| {k} | {a} | " + " | ".join("–" if x is None else f"{x:.3f}" for x in v) + " |")


assert PAD == 114
if __name__ == "__main__":
    main()
