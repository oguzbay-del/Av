# Kaggle betiği (GPU T4 ×2 + internet açık): kuş bulucuyu (YOLOX-S, resmi Megvii eğitim kodu, Apache-2.0) tek sınıf
# "bird" için ince ayarlar, eski COCO modeliyle karşılaştırır ve Core ML'e çevirir.
# Gönderim: kaggle kernels push -p tools/kus_bulucu/kaggle/egitim   (veri: kaggle/veri betiğinin çıktısı)
# Çıktı (/kaggle/working/cikti): latest/best ckpt, train_log.txt, metrikler.json, BirdDetector_*.mlpackage.tar,
# beklenen_*.json (dogrula.py için PyTorch kutuları), sure.json.
# MOD=hiz: kısa deneme (train_hiz.json, 2 tur ≈ 400 adım: 1 mosaic + 1 mosaicsiz) + tüm ölçüm/aktarma zinciri.
import glob
import json
import os
import shutil
import subprocess
import sys
import time

DAL = os.environ.get("DAL", "main")
MOD = os.environ.get("MOD", "tam")
EPOCHS = int(os.environ.get("EPOCHS", "30"))
NO_AUG = int(os.environ.get("NO_AUG", "5"))
BATCH = int(os.environ.get("BATCH", "32"))
T0 = time.time()
CIKTI = "/kaggle/working/cikti"
IS = "/tmp/is"
AV = "/tmp/Av/tools/kus_bulucu"
PY = sys.executable
sure = {}


def sh(cmd, check=True):
    print(f"\n$ {cmd}", flush=True)
    t0 = time.time()
    r = subprocess.run(cmd, shell=True)
    print(f"[{(time.time() - t0) / 60:.1f} dk, çıkış {r.returncode}]", flush=True)
    if r.returncode and check:
        sys.exit(r.returncode)
    return time.time() - t0


os.makedirs(CIKTI, exist_ok=True)
sh("nvidia-smi -L || true; nproc; free -g | head -2")
sh(f"rm -rf /tmp/Av && git clone -q --depth 1 -b {DAL} https://github.com/oguzbay-del/Av /tmp/Av")
sh("pip install -q pycocotools loguru thop tabulate ninja psutil coremltools")
arsiv = next(iter(glob.glob("/kaggle/input/**/veri.tar", recursive=True)), None)
if not arsiv:
    sys.exit("veri.tar yok: önce kaggle/veri betiğini çalıştırın")
sh(f"mkdir -p /tmp/veri && tar -C /tmp/veri -xf {arsiv} && du -sh /tmp/veri")
os.environ.update({"IS": IS, "VERI": "/tmp/veri", "PYTHONPATH": f"{IS}/YOLOX",
                   "TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD": "1", "CIKTI_EGITIM": "/tmp/egitim", "ISCI": "3"})
sh(f"{PY} {AV}/kus_bulucu.py baslangic")

out = subprocess.run("nvidia-smi -L", shell=True, capture_output=True, text=True).stdout
gpus = max(1, sum(1 for s in out.splitlines() if s.startswith("GPU ")))
if MOD == "hiz":
    os.environ.update({"TRAIN_ANN": "train_hiz.json", "EPOCHS": "2", "NO_AUG": "1", "EVAL_INTERVAL": "1"})
else:
    os.environ.update({"TRAIN_ANN": "train.json", "EPOCHS": str(EPOCHS), "NO_AUG": str(NO_AUG),
                       "EVAL_INTERVAL": "5"})
sure["hazirlik_dk"] = round((time.time() - T0) / 60, 1)
sure["egitim_dk"] = round(sh(f"cd {IS}/YOLOX && {PY} tools/train.py -f {AV}/yolox_kus_exp.py -d {gpus} -b {BATCH} "
                             f"--fp16 -c {IS}/yolox_s_kus_baslangic.pth") / 60, 1)
d = "/tmp/egitim/kus_bulucu"
for f in ("latest_ckpt.pth", "best_ckpt.pth", "train_log.txt"):
    if os.path.exists(f"{d}/{f}"):
        shutil.copy(f"{d}/{f}", CIKTI)
sh(f"grep -E 'iter_time|Average Precision' {d}/train_log.txt | tail -40", check=False)

t = time.time()
sh(f"{PY} {AV}/degerlendir.py /tmp/veri {CIKTI}/metrikler.json eski={IS}/yolox_s.pth "
   f"yeni_son={d}/latest_ckpt.pth yeni_en_iyi={d}/best_ckpt.pth")
sure["olcum_dk"] = round((time.time() - t) / 60, 1)

# Core ML: son tur ağırlığı ve izleme kümesinde en iyi ağırlık ayrı paketler
for ad, ck in (("son", "latest_ckpt.pth"), ("en_iyi", "best_ckpt.pth")):
    sh(f"AGIRLIK={d}/{ck} {PY} {AV}/kus_bulucu.py aktar && AGIRLIK={d}/{ck} {PY} {AV}/kus_bulucu.py ornek")
    sh(f"tar -C {IS} -cf {CIKTI}/BirdDetector_{ad}.mlpackage.tar BirdDetector.mlpackage && "
       f"cp {AV}/ornekler/beklenen.json {CIKTI}/beklenen_{ad}.json")
sure["toplam_dk"] = round((time.time() - T0) / 60, 1)
sure.update({"gpus": gpus, "mod": MOD, "batch": BATCH, "epochs": int(os.environ["EPOCHS"])})
json.dump(sure, open(f"{CIKTI}/sure.json", "w"), indent=1)
print("SÜRE", json.dumps(sure), flush=True)
sh(f"ls -la {CIKTI}")
print("BİTTİ", flush=True)
