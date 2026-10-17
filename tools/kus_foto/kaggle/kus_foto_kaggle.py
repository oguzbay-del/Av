# Kaggle betiği: kuş fotoğrafı modelini baştan sona eğitir (GPU T4 ×2 + internet açık).
# Gönderim: kaggle kernels push -p tools/kus_foto/kaggle   (tools/kus_foto/kaggle/kernel-metadata.json)
# Çıktı (/kaggle/working/cikti): Core ML modelleri, metrikler, performans, doğrulama örnekleri, künye.
# Akış: veri arşivini aç → BioCLIP 2 öğretmen etiketleri (bir kez; önceki çıktıda varsa kullanılır) →
# kısa hız denemesi (DDP ve tek GPU; DDP başarısız ya da yavaşsa GPUS=1) → tur sayısını 12 saatlik
# oturuma sığdır → eğit (torchrun) → değerlendir → performans → Core ML.
# SADECE_HIZ=1: yalnızca öğretmen + hız denemesi (tam eğitim yok).
import glob
import json
import os
import shutil
import subprocess
import sys
import time

DAL = os.environ.get("DAL", "main")
SADECE_HIZ = os.environ.get("SADECE_HIZ", "0") == "1"
HEDEF_TUR = int(os.environ.get("EPOCHS", "30"))
OTURUM_SAAT = 12.0  # Kaggle GPU oturum sınırı
SONRASI_DK = 45  # değerlendir + performans + aktar
PAY_DK = 40  # güvenlik payı
T0 = time.time()


def sh(cmd, check=True):
    print(f"\n$ {cmd}", flush=True)
    t0 = time.time()
    r = subprocess.run(cmd, shell=True)
    print(f"[{(time.time() - t0) / 60:.1f} dk, çıkış {r.returncode}]", flush=True)
    if r.returncode and check:
        sys.exit(r.returncode)
    return r.returncode


sh("nvidia-smi -L || true")
sh(f"rm -rf /tmp/Av && git clone -q --depth 1 -b {DAL} https://github.com/oguzbay-del/Av /tmp/Av")
sh("pip install -q -U timm coremltools open_clip_torch")
os.environ.update({
    "VERI": "/tmp/veri", "YEDEK": "/tmp/yedek", "CIKTI": "/kaggle/working/cikti",
    "YEDEK_VERI": "0", "DEPO": "/tmp/Av", "OGRETMEN": "/kaggle/working/ogretmen.pt",
})
KF = "/tmp/Av/tools/kus_foto/kus_foto.py"
K = f"{sys.executable} {KF}"
TORCHRUN = f"{sys.executable} -m torch.distributed.run --standalone"
# Fotoğraflar ayrı veri betiğinin çıktısından gelir (kernel_sources); yoksa burada indirilir
arsiv = next(iter(glob.glob("/kaggle/input/**/veri.tar", recursive=True)), None)
if arsiv:
    sh(f"mkdir -p /tmp/veri && tar -C /tmp/veri -xf {arsiv} && du -sh /tmp/veri")
else:
    sh(f"{K} indir")

# Bilgi damıtma öğretmeni: önceki bir çalıştırmanın çıktısı varsa yeniden hesaplanmaz
if os.environ.get("KD", "0.5") not in ("0", "0.0"):
    onceki = next(iter(glob.glob("/kaggle/input/**/ogretmen.pt", recursive=True)), None)
    if onceki:
        shutil.copy(onceki, os.environ["OGRETMEN"])
    if sh(f"{K} ogretmen", check=False):
        print("Öğretmen etiketleri hesaplanamadı: damıtmasız devam", flush=True)
        os.environ["KD"] = "0"

# Hız denemesi
out = subprocess.run("nvidia-smi -L", shell=True, capture_output=True, text=True).stdout
gpus = max(1, sum(1 for s in out.splitlines() if s.startswith("GPU ")))


def hiz(n, steps):
    f = f"/tmp/hiz_{n}.json"
    run = f"{TORCHRUN} --nproc_per_node={n} {KF}" if n > 1 else K
    env = f"GPUS={n} HIZ_DOSYA={f} EPOCHS=1 MAX_STEPS={steps} LOG_EVERY=20 YEDEK=/tmp/yedek_hiz"
    rc = sh(f"rm -f {f}; {env} {run} egit", check=False)
    return json.load(open(f)) if rc == 0 and os.path.exists(f) else None


sonuc = {"gpus_visible": gpus}
if gpus > 1:
    sonuc["ddp"] = hiz(gpus, 100)
sonuc["single"] = hiz(1, 60)
ddp, tek = sonuc.get("ddp"), sonuc["single"]
if ddp and (not tek or ddp["images_per_s"] >= 1.25 * tek["images_per_s"]):
    secilen, gpus = ddp, gpus
else:
    secilen, gpus = tek, 1
    if sonuc.get("ddp") is None and sonuc["gpus_visible"] > 1:
        print("DDP hız denemesi başarısız: tek GPU ile devam", flush=True)
if not secilen:
    sys.exit("Hız denemesi başarısız")
sonuc["chosen_gpus"] = gpus

# Tur sayısını oturuma sığdır (doğrulama dahil tur süresi tahmini)
tur_dk = secilen["n_train"] / secilen["images_per_s"] / 60 * 1.05 + 1.5
kalan_dk = OTURUM_SAAT * 60 - (time.time() - T0) / 60 - SONRASI_DK - PAY_DK
tur = max(3, min(HEDEF_TUR, int(kalan_dk // tur_dk)))
sonuc.update({"epoch_minutes_est": round(tur_dk, 1), "epochs": tur, "train_hours_est": round(tur * tur_dk / 60, 2)})
print("HIZ ÖZETİ", json.dumps(sonuc, ensure_ascii=False), flush=True)
os.makedirs("/kaggle/working/cikti", exist_ok=True)
json.dump(sonuc, open("/kaggle/working/cikti/hiz.json", "w"), indent=1, ensure_ascii=False)
if tur < HEDEF_TUR:
    print(f"UYARI: {HEDEF_TUR} tur oturuma sığmıyor, {tur} tur eğitilecek", flush=True)
if SADECE_HIZ:
    print("BİTTİ (yalnızca hız denemesi)", flush=True)
    sys.exit(0)

os.environ.update({"GPUS": str(gpus), "EPOCHS": str(tur)})
sh(f"{TORCHRUN} --nproc_per_node={gpus} {KF} egit" if gpus > 1 else f"{K} egit")
for step in ["degerlendir", "performans", "aktar"]:
    sh(f"{K} {step}")
for f in ("egitim_gecmisi.json",):
    if os.path.exists(f"/tmp/yedek/{f}"):
        shutil.copy(f"/tmp/yedek/{f}", "/kaggle/working/cikti/")
sh("du -sh /kaggle/working/cikti/* | sort -h | tail")
print("BİTTİ", flush=True)
