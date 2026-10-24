#!/usr/bin/env python3
"""Kuş bulucu ince ayarı için veri: Open Images V7 + COCO 2017 kuş kutuları → COCO biçimi.

  python veri.py          VERI klasörüne (varsayılan ./veri) indirir ve hazırlar

Kaynaklar ve lisanslar (ayrıntı: VERI/kunye.csv.gz ve VERI/kunye.json):
  - Open Images V7 (Google): kutu etiketleri CC BY 4.0, görüntüler CC BY 2.0 (Flickr; her görüntünün sahibi
    künyede). "Bird" (/m/015p6) ve hiyerarşideki tüm alt sınıfları (ördek, kartal, baykuş...) tek sınıf "bird".
  - COCO 2017: etiketler CC BY 4.0. Görüntüler Flickr'dan, karışık CC lisanslı; EĞİTİMDE yalnızca ticari olmayan
    (NC) kısıtı taşımayan lisanslar kullanılır (BY, BY-SA, BY-ND, telif bilinmiyor, ABD kamu). Sınamada
    (yalnızca ölçüm, modele girmez) tüm val2017 görüntüleri kullanılır.
  CUB-200 / NABirds gibi yalnızca araştırma lisanslı veri KULLANILMAZ.

Çıktı (YOLOX COCODataset düzeni, name="images"):
  VERI/images/*.jpg       en uzun kenar en çok 640 (uygulama girdisi 640; YOLOX da 640'a küçültür), EXIF'siz
  VERI/annotations/
    train.json            OI train kuş görüntüleri (grup kutusuz) + COCO train2017 kuşlu + kuşsuz (negatif)
    train_hiz.json        hız denemesi için train alt kümesi
    izleme.json           eğitim sırasında izleme: eğitime girmeyen 500 OI train görüntüsü
    oi_test.json          SINAMA: OI validation + test kuş görüntüleri (grup kutusuz)
    coco_val.json         SINAMA: COCO val2017 kuşlu görüntüler
    coco_neg.json         SINAMA: COCO val2017 kuşsuz görüntüler (yanlış alarm oranı)
Grup kutusu (IsGroupOf: sürü tek kutu) içeren görüntüler atılır (YOLOX'ta yok sayma bölgesi yok); yalnızca
Rotation = 0 olan OI görüntüleri alınır (kutular döndürülmemiş piksele göre). Eğitimde tasvir kutulu (IsDepiction:
çizim, heykel, oyuncak kuş) OI görüntüleri de atılır: COCO'da bunlar kuş sayılmaz, yanlış alarmı artırıyordu.

Ortam: VERI, OI_TRAIN_EN_COK (varsayılan 16000), COCO_NEG_TRAIN (12000), IS_PARCACIGI (32).
"""
import collections
import concurrent.futures as cf
import csv
import gzip
import io
import json
import os
import random
import subprocess
import sys
import urllib.request
import zipfile

VERI = os.path.abspath(os.environ.get("VERI", "veri"))
HAM = os.path.join(VERI, "ham")
IMG = os.path.join(VERI, "images")
ANN = os.path.join(VERI, "annotations")
OI_TRAIN_EN_COK = int(os.environ.get("OI_TRAIN_EN_COK", "16000"))
COCO_NEG_TRAIN = int(os.environ.get("COCO_NEG_TRAIN", "12000"))
IZLEME = 500
HIZ = 6400
PARCACIK = int(os.environ.get("IS_PARCACIGI", "32"))
EN_BUYUK = 640
OI = "https://storage.googleapis.com/openimages"
OI_IMG = "https://open-images-dataset.s3.amazonaws.com"  # CVDF aynası
COCO_IMG = "http://images.cocodataset.org"
COCO_ANN = "http://images.cocodataset.org/annotations/annotations_trainval2017.zip"
COCO_BIRD = 16
# COCO lisans kimlikleri: 1 BY-NC-SA, 2 BY-NC, 3 BY-NC-ND, 4 BY, 5 BY-SA, 6 BY-ND, 7 telif bilinmiyor, 8 ABD kamu
COCO_TICARI_SERBEST = {4, 5, 6, 7, 8}
random.seed(20261023)


def sh(cmd):
    print("$", cmd, flush=True)
    subprocess.check_call(cmd, shell=True)


def indir(url, dst):
    if not os.path.exists(dst):
        sh(f"curl -sSfL --retry 5 -o {dst}.part '{url}' && mv {dst}.part {dst}")
    return dst


def kus_etiketleri():
    from PIL import Image  # noqa: F401  (erken hata: pillow kurulu olmalı)
    h = json.load(open(indir(f"{OI}/2018_04/bbox_labels_600_hierarchy.json", f"{HAM}/hiyerarsi.json")))
    adlar = dict(csv.reader(open(indir(f"{OI}/v7/oidv7-class-descriptions-boxable.csv", f"{HAM}/siniflar.csv"))))

    def bul(n):
        if n["LabelName"] == "/m/015p6":
            return n
        for c in n.get("Subcategory", []):
            r = bul(c)
            if r:
                return r

    etiket = []

    def gez(n):
        etiket.append(n["LabelName"])
        for c in n.get("Subcategory", []):
            gez(c)

    gez(bul(h))
    print("OI kuş sınıfları:", [adlar.get(e, e) for e in etiket], flush=True)
    return set(etiket), {e: adlar.get(e, e) for e in etiket}


def oi_kutular(bolum, etiket):
    """Bölümdeki kuş kutuları: {ImageID: [satır]} (büyük train dosyası grep ile süzülerek akıtılır)."""
    url = {"train": f"{OI}/v6/oidv6-train-annotations-bbox.csv",
           "validation": f"{OI}/v5/validation-annotations-bbox.csv",
           "test": f"{OI}/v5/test-annotations-bbox.csv"}[bolum]
    suz = f"{HAM}/oi_{bolum}_kus.csv"
    if not os.path.exists(suz):
        desen = f"{HAM}/etiket.txt"
        with open(desen, "w") as fh:
            fh.write("\n".join("," + e + "," for e in sorted(etiket)) + "\n")
        sh(f"curl -sSfL --retry 5 '{url}' | grep -F -f {desen} > {suz}.part; mv {suz}.part {suz}")
    alan = ["ImageID", "Source", "LabelName", "Confidence", "XMin", "XMax", "YMin", "YMax",
            "IsOccluded", "IsTruncated", "IsGroupOf", "IsDepiction", "IsInside"]
    kutu = collections.defaultdict(list)
    for r in csv.DictReader(open(suz), fieldnames=alan):
        if r["LabelName"] in etiket:
            kutu[r["ImageID"]].append(r)
    return kutu


def oi_bilgi(bolum, ids):
    url = {"train": f"{OI}/2018_04/train/train-images-boxable-with-rotation.csv",
           "validation": f"{OI}/2018_04/validation/validation-images-with-rotation.csv",
           "test": f"{OI}/2018_04/test/test-images-with-rotation.csv"}[bolum]
    yol = indir(url, f"{HAM}/oi_{bolum}_bilgi.csv")
    return {r["ImageID"]: r for r in csv.DictReader(open(yol, encoding="utf-8")) if r["ImageID"] in ids}


def kaydet(veri, dosya):
    """Ham JPEG baytı → en uzun kenar ≤ 640, RGB, EXIF'siz JPEG; (genişlik, yükseklik) ya da None."""
    from PIL import Image
    try:
        im = Image.open(io.BytesIO(veri))
        im.load()
        w0, h0 = im.size
        im = im.convert("RGB")
        r = min(1.0, EN_BUYUK / max(w0, h0))
        if r < 1:
            im = im.resize((max(1, round(w0 * r)), max(1, round(h0 * r))), Image.BILINEAR)
        im.save(os.path.join(IMG, dosya), quality=92)
        return im.size, (w0, h0)
    except Exception as e:  # bozuk görüntü
        print("atlandı", dosya, e, flush=True)
        return None


def getir(url, dosya):
    yol = os.path.join(IMG, dosya)
    if os.path.exists(yol):
        from PIL import Image
        with Image.open(yol) as im:
            return im.size, None
    for deneme in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return kaydet(r.read(), dosya)
        except Exception as e:
            if deneme == 3:
                print("indirilemedi", url, e, flush=True)
    return None


def toplu_getir(isler):
    """isler: [(anahtar, url, dosya)] → {anahtar: ((w, h), asıl boyut)}"""
    sonuc = {}
    with cf.ThreadPoolExecutor(PARCACIK) as ex:
        fut = {ex.submit(getir, u, d): k for k, u, d in isler}
        for i, f in enumerate(cf.as_completed(fut)):
            r = f.result()
            if r:
                sonuc[fut[f]] = r
            if (i + 1) % 2000 == 0:
                print(f"  {i + 1}/{len(isler)} görüntü", flush=True)
    return sonuc


class Coco:
    def __init__(self):
        self.images, self.annotations = [], []

    def ekle(self, dosya, w, h, kutular):
        """kutular: [(x, y, w, h, iscrowd, area)] piksel."""
        iid = len(self.images) + 1
        self.images.append({"id": iid, "file_name": dosya, "width": w, "height": h})
        for x, y, bw, bh, crowd, area in kutular:
            self.annotations.append({"id": len(self.annotations) + 1, "image_id": iid, "category_id": 1,
                                     "bbox": [round(x, 2), round(y, 2), round(bw, 2), round(bh, 2)],
                                     "area": round(area, 2), "iscrowd": crowd})

    def yaz(self, ad):
        with open(os.path.join(ANN, ad), "w") as fh:
            json.dump({"images": self.images, "annotations": self.annotations,
                       "categories": [{"id": 1, "name": "bird", "supercategory": "animal"}]}, fh)
        print(f"{ad}: {len(self.images)} görüntü, {len(self.annotations)} kutu", flush=True)


def oi_hazirla(bolumler, etiket, en_cok=None, kunye=None, ad="", tasvir_at=False):
    """OI bölümlerinden kuş görüntüleri → [(dosya, w, h, kutular)]."""
    adaylar = []
    for b in bolumler:
        kutu = oi_kutular(b, etiket)
        bilgi = oi_bilgi(b, set(kutu))
        grup = rot = tasvir = 0
        for iid, kl in kutu.items():
            if any(k["IsGroupOf"] == "1" for k in kl):
                grup += 1
                continue
            if tasvir_at and any(k["IsDepiction"] == "1" for k in kl):
                tasvir += 1
                continue
            bi = bilgi.get(iid)
            if not bi or bi.get("Rotation") not in ("0", "0.0"):
                rot += 1
                continue
            adaylar.append((b, iid, kl, bi))
        print(f"OI {b}: {len(kutu)} kuşlu görüntü; grup kutulu {grup}, tasvirli {tasvir}, döndürülmüş/bilinmeyen {rot} atıldı",
              flush=True)
    random.shuffle(adaylar)
    if en_cok and len(adaylar) > en_cok:
        # küçük kuşlu görüntüler önce (640'lık girdide alan < 32² olan kutu)
        def kucuk(a):
            return any((float(k["XMax"]) - float(k["XMin"])) * (float(k["YMax"]) - float(k["YMin"])) * 640 * 480
                       < 32 * 32 for k in a[2])
        adaylar.sort(key=lambda a: not kucuk(a))
        adaylar = adaylar[:en_cok]
        random.shuffle(adaylar)
    isler = [((b, iid), f"{OI_IMG}/{b}/{iid}.jpg", f"oi_{iid}.jpg") for b, iid, _, _ in adaylar]
    boyut = toplu_getir(isler)
    cikti = []
    for b, iid, kl, bi in adaylar:
        if (b, iid) not in boyut:
            continue
        (w, h), _ = boyut[(b, iid)]
        kutular = []
        for k in kl:
            x0, x1 = float(k["XMin"]) * w, float(k["XMax"]) * w
            y0, y1 = float(k["YMin"]) * h, float(k["YMax"]) * h
            if x1 - x0 >= 1 and y1 - y0 >= 1:
                kutular.append((x0, y0, x1 - x0, y1 - y0, 0, (x1 - x0) * (y1 - y0)))
        cikti.append((f"oi_{iid}.jpg", w, h, kutular))
        if kunye is not None:
            kunye.append([ad, f"oi_{iid}.jpg", "Open Images V7 " + b, bi.get("License", ""), bi.get("Author", ""),
                          bi.get("OriginalLandingURL", "")])
    return cikti


def coco_hazirla(kunye):
    z = indir(COCO_ANN, f"{HAM}/coco_ann.zip")
    out = {}
    with zipfile.ZipFile(z) as zf:
        for bolum in ("train2017", "val2017"):
            d = json.load(zf.open(f"annotations/instances_{bolum}.json"))
            lis = {li["id"]: li["url"] for li in d["licenses"]}
            kus = collections.defaultdict(list)
            for a in d["annotations"]:
                if a["category_id"] == COCO_BIRD:
                    kus[a["image_id"]].append(a)
            out[bolum] = (d["images"], kus, lis)
    tr_img, tr_kus, lis = out["train2017"]
    serbest = [im for im in tr_img if im["license"] in COCO_TICARI_SERBEST]
    tr_poz = [im for im in serbest if im["id"] in tr_kus]
    tr_neg = random.sample([im for im in serbest if im["id"] not in tr_kus], COCO_NEG_TRAIN)
    print(f"COCO train2017: kuşlu {len(tr_kus)} görüntü, NC'siz lisanslı {len(tr_poz)}; negatif {len(tr_neg)}",
          flush=True)
    va_img, va_kus, _ = out["val2017"]
    va_poz = [im for im in va_img if im["id"] in va_kus]
    va_neg = [im for im in va_img if im["id"] not in va_kus]

    def yap(imler, bolum, kus, ad):
        isler = [(im["id"], f"{COCO_IMG}/{bolum}/{im['file_name']}", f"coco_{im['file_name']}") for im in imler]
        boyut = toplu_getir(isler)
        sonuc = []
        for im in imler:
            if im["id"] not in boyut:
                continue
            (w, h), asil = boyut[im["id"]]
            s = w / im["width"]  # COCO görüntüleri zaten ≤ 640: s = 1
            kutular = [(a["bbox"][0] * s, a["bbox"][1] * s, a["bbox"][2] * s, a["bbox"][3] * s, a["iscrowd"],
                        a["area"] * s * s) for a in kus.get(im["id"], [])]
            sonuc.append((f"coco_{im['file_name']}", w, h, kutular))
            if kunye is not None and ad:
                kunye.append([ad, f"coco_{im['file_name']}", "COCO " + bolum, lis.get(im["license"], ""), "",
                              im.get("flickr_url", "")])
        return sonuc

    return (yap(tr_poz, "train2017", tr_kus, "train"), yap(tr_neg, "train2017", tr_kus, "train"),
            yap(va_poz, "val2017", va_kus, "test"), yap(va_neg, "val2017", va_kus, "test"))


def coco_yaz(kayitlar, ad):
    c = Coco()
    for dosya, w, h, k in kayitlar:
        c.ekle(dosya, w, h, k)
    c.yaz(ad)
    return c


def main():
    for d in (HAM, IMG, ANN):
        os.makedirs(d, exist_ok=True)
    etiket, adlar = kus_etiketleri()
    kunye = []
    oi_tr = oi_hazirla(["train"], etiket, OI_TRAIN_EN_COK + IZLEME, kunye, "train", tasvir_at=True)
    izleme, oi_tr = oi_tr[:IZLEME], oi_tr[IZLEME:]
    izleme_ad = {i[0] for i in izleme}
    for r in kunye:
        if r[1] in izleme_ad:
            r[0] = "izleme"
    oi_te = oi_hazirla(["validation", "test"], etiket, None, kunye, "test")
    co_tr, co_neg, co_va, co_va_neg = coco_hazirla(kunye)

    train = oi_tr + co_tr + co_neg
    random.shuffle(train)
    coco_yaz(train, "train.json")
    coco_yaz(train[:HIZ], "train_hiz.json")
    coco_yaz(izleme, "izleme.json")
    coco_yaz(oi_te, "oi_test.json")
    coco_yaz(co_va, "coco_val.json")
    coco_yaz(co_va_neg, "coco_neg.json")

    ozet = {
        "oi_bird_classes": sorted(adlar.values()),
        "train": {"oi_images": len(oi_tr), "oi_boxes": sum(len(k) for *_, k in oi_tr),
                  "coco_bird_images": len(co_tr), "coco_bird_boxes": sum(len(k) for *_, k in co_tr),
                  "coco_negative_images": len(co_neg)},
        "izleme_images": len(izleme),
        "test": {"oi_images": len(oi_te), "oi_boxes": sum(len(k) for *_, k in oi_te),
                 "coco_val_bird_images": len(co_va), "coco_val_bird_boxes": sum(len(k) for *_, k in co_va),
                 "coco_val_negative_images": len(co_va_neg)},
        "licenses": {
            "Open Images V7": "annotations CC BY 4.0 (Google LLC); images CC BY 2.0 (Flickr authors, see kunye)",
            "COCO 2017": "annotations CC BY 4.0 (COCO Consortium); train images used only with non-NC "
                         "licenses (CC BY, BY-SA, BY-ND, no known copyright, US Gov); val2017 for testing only",
        },
    }
    json.dump(ozet, open(os.path.join(VERI, "kunye.json"), "w"), indent=1, ensure_ascii=False)
    with gzip.open(os.path.join(VERI, "kunye.csv.gz"), "wt", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["split", "file", "source", "license", "author", "url"])
        w.writerows(kunye)
    print(json.dumps(ozet, indent=1, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    sys.exit(main())
