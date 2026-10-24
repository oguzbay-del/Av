# Kaggle betiği (GPU T4 + internet açık): kuş bulucuyu (YOLOX-S, resmi Megvii eğitim kodu, Apache-2.0) tek sınıf
# "bird" için ince ayarlar, eski COCO modeliyle karşılaştırır ve Core ML'e çevirir.
# Gönderim: kaggle kernels push -p tools/kus_bulucu/kaggle/egitim   (veri: kaggle/veri betiğinin çıktısı)
# Çıktı (/kaggle/working/cikti): latest/best ckpt, train_log.txt, metrikler.json, BirdDetector_*.mlpackage.tar,
# beklenen_*.json (dogrula.py için PyTorch kutuları), sure.json.
# MOD=hiz: kısa deneme (train_hiz.json, 2 tur ≈ 400 adım: 1 mosaic + 1 mosaicsiz) + tüm ölçüm/aktarma zinciri.
# MOD=tam: önce 100 adımlık hız ölçümü, tur sayısı EGITIM_DK'ya (varsayılan 110 dk) sığdırılır (en çok EPOCHS).
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

DAL = os.environ.get("DAL", "main")
MOD = os.environ.get("MOD", "tam")
EPOCHS = int(os.environ.get("EPOCHS", "30"))
NO_AUG = int(os.environ.get("NO_AUG", "5"))
BATCH = int(os.environ.get("BATCH", "32"))
EGITIM_DK = float(os.environ.get("EGITIM_DK", "110"))
# Tek GPU: hız denemesinde (2×T4, DDP) veri yükleme (4 çekirdek, mosaic/mixup) darboğazdı, ikinci GPU hız
# kazandırmadı ve DDP tur sonu ölçümünden sonra kilitlendi (NCCL zaman aşımı). GPUS=2 ile DDP denenebilir.
GPUS = int(os.environ.get("GPUS", "1"))
T0 = time.time()
CIKTI = "/kaggle/working/cikti"
IS = "/tmp/is"
AV = "/tmp/Av/tools/kus_bulucu"
PY = sys.executable
TRAIN = (f"cd {IS}/YOLOX && {PY} tools/train.py -f {AV}/yolox_kus_exp.py -d {GPUS} -b {BATCH} --fp16 "
         f"-c {IS}/yolox_s_kus_baslangic.pth")
sure = {}


def sh(cmd, check=True):
    print(f"\n$ {cmd}", flush=True)
    t0 = time.time()
    r = subprocess.run(cmd, shell=True)
    print(f"[{(time.time() - t0) / 60:.1f} dk, çıkış {r.returncode}]", flush=True)
    if r.returncode and check:
        sys.exit(r.returncode)
    return time.time() - t0


def hiz_olc(adim=200):
    """train_hiz.json (turu 200 adım) ile mosaic'li kısa eğitim; 120.–adim. adımların ortalama iter_time'ı (sn).
    İlk adımlar yavaştır (her yeni çok ölçekli boyutta cudnn.benchmark): 1. çalıştırmada 40.–100. adımlar
    1,84 sn/adım ölçüldü, eğitimin geneli ≈ 0,75 sn/adım sürdü."""
    env = dict(os.environ, TRAIN_ANN="train_hiz.json", EPOCHS="2", NO_AUG="1", EVAL_INTERVAL="1000",
               CIKTI_EGITIM="/tmp/egitim_hiz")
    log = "/tmp/egitim_hiz/kus_bulucu/train_log.txt"
    p = subprocess.Popen(TRAIN, shell=True, env=env, start_new_session=True)
    t0 = time.time()
    sonuc = None
    while p.poll() is None and time.time() - t0 < 1800:
        time.sleep(15)
        if os.path.exists(log):
            v = [(int(a), float(b)) for a, b in re.findall(r"iter: (\d+)/\d+.*?iter_time: ([\d.]+)s", open(log).read())]
            if v and v[-1][0] >= adim:
                son = [t for i, t in v if i > 120]
                sonuc = sum(son) / len(son)
                break
    if p.poll() is None:
        os.killpg(p.pid, 9)
    p.wait()
    print("hız ölçümü (sn/adım):", sonuc, flush=True)
    return sonuc


os.makedirs(CIKTI, exist_ok=True)
sh("nvidia-smi -L || true; nproc; free -g | head -2")
sh(f"rm -rf /tmp/Av && git clone -q --depth 1 -b {DAL} https://github.com/oguzbay-del/Av /tmp/Av")
sh("pip install -q pycocotools loguru thop tabulate ninja psutil coremltools")
arsiv = next(iter(glob.glob("/kaggle/input/**/veri.tar", recursive=True)), None)
if not arsiv:
    sys.exit("veri.tar yok: önce kaggle/veri betiğini çalıştırın")
sh(f"mkdir -p /tmp/veri && tar -C /tmp/veri -xf {arsiv} && du -sh /tmp/veri")
os.environ.update({"IS": IS, "VERI": "/tmp/veri", "PYTHONPATH": f"{IS}/YOLOX",
                   "TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD": "1", "CIKTI_EGITIM": "/tmp/egitim",
                   "ISCI": str(max(2, 4 // GPUS))})
sh(f"{PY} {AV}/kus_bulucu.py baslangic")

if MOD == "hiz":
    os.environ.update({"TRAIN_ANN": "train_hiz.json", "EPOCHS": "2", "NO_AUG": "1", "EVAL_INTERVAL": "1"})
else:
    n_train = len(json.load(open("/tmp/veri/annotations/train.json"))["images"])
    it = hiz_olc()
    tur_dk = n_train / BATCH * (it or 0.9) / 60 * 1.05
    epochs = max(6, min(EPOCHS, int(EGITIM_DK // tur_dk)))
    no_aug = max(2, min(NO_AUG, epochs // 6))
    sure.update({"iter_s": it, "tur_dk_tahmin": round(tur_dk, 1), "n_train": n_train})
    print(f"TUR: {epochs} (tur ≈ {tur_dk:.1f} dk, mosaicsiz son {no_aug})", flush=True)
    os.environ.update({"TRAIN_ANN": "train.json", "EPOCHS": str(epochs), "NO_AUG": str(no_aug),
                       "EVAL_INTERVAL": "5"})
sure["hazirlik_dk"] = round((time.time() - T0) / 60, 1)
sure["egitim_dk"] = round(sh(TRAIN) / 60, 1)
d = "/tmp/egitim/kus_bulucu"
for f in ("latest_ckpt.pth", "best_ckpt.pth", "train_log.txt"):
    if os.path.exists(f"{d}/{f}"):
        shutil.copy(f"{d}/{f}", CIKTI)
sh(f"grep -E 'iter_time|Average Precision' {d}/train_log.txt | tail -40", check=False)
if not os.path.exists(f"{d}/latest_ckpt.pth"):
    sys.exit("eğitim ağırlığı yok")
ckpts = [(ad, ck) for ad, ck in (("son", "latest_ckpt.pth"), ("en_iyi", "best_ckpt.pth"))
         if os.path.exists(f"{d}/{ck}")]

t = time.time()
sh(f"{PY} {AV}/degerlendir.py /tmp/veri {CIKTI}/metrikler.json eski={IS}/yolox_s.pth "
   + " ".join(f"yeni_{ad}={d}/{ck}" for ad, ck in ckpts))
sure["olcum_dk"] = round((time.time() - t) / 60, 1)

# Core ML: son tur ağırlığı ve izleme kümesinde en iyi ağırlık ayrı paketler
for ad, ck in ckpts:
    sh(f"AGIRLIK={d}/{ck} {PY} {AV}/kus_bulucu.py aktar && AGIRLIK={d}/{ck} {PY} {AV}/kus_bulucu.py ornek")
    sh(f"tar -C {IS} -cf {CIKTI}/BirdDetector_{ad}.mlpackage.tar BirdDetector.mlpackage && "
       f"cp {AV}/ornekler/beklenen.json {CIKTI}/beklenen_{ad}.json")
sure["toplam_dk"] = round((time.time() - T0) / 60, 1)
sure.update({"gpus": GPUS, "mod": MOD, "batch": BATCH, "epochs": int(os.environ["EPOCHS"])})
json.dump(sure, open(f"{CIKTI}/sure.json", "w"), indent=1)
print("SÜRE", json.dumps(sure), flush=True)
sh(f"ls -la {CIKTI}")
print("BİTTİ", flush=True)
