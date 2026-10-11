# Kaggle betiği: kuş fotoğrafı modelini baştan sona eğitir (GPU + internet açık).
# Gönderim: kaggle kernels push -p tools/kus_foto/kaggle   (tools/kus_foto/kaggle/kernel-metadata.json)
# Çıktı (/kaggle/working/cikti): Core ML modelleri, metrikler, performans, doğrulama örnekleri, künye.
import glob
import os
import shutil
import subprocess
import sys
import time

DAL = os.environ.get("DAL", "main")


def sh(cmd):
    print(f"\n$ {cmd}", flush=True)
    t0 = time.time()
    r = subprocess.run(cmd, shell=True)
    print(f"[{(time.time() - t0) / 60:.1f} dk, çıkış {r.returncode}]", flush=True)
    if r.returncode:
        sys.exit(r.returncode)


sh("nvidia-smi -L || true")
sh(f"rm -rf /tmp/Av && git clone -q --depth 1 -b {DAL} https://github.com/oguzbay-del/Av /tmp/Av")
sh("pip install -q -U timm coremltools")
os.environ.update({
    "VERI": "/tmp/veri", "YEDEK": "/tmp/yedek", "CIKTI": "/kaggle/working/cikti",
    "YEDEK_VERI": "0", "DEPO": "/tmp/Av",
})
K = f"{sys.executable} /tmp/Av/tools/kus_foto/kus_foto.py"
# Fotoğraflar ayrı veri betiğinin çıktısından gelir (kernel_sources); yoksa burada indirilir
arsiv = next(iter(glob.glob("/kaggle/input/**/veri.tar", recursive=True)), None)
steps = ["egit", "degerlendir", "performans", "aktar"]
if arsiv:
    sh(f"mkdir -p /tmp/veri && tar -C /tmp/veri -xf {arsiv} && du -sh /tmp/veri")
else:
    steps.insert(0, "indir")
for step in steps:
    sh(f"{K} {step}")
for f in ("egitim_gecmisi.json",):
    if os.path.exists(f"/tmp/yedek/{f}"):
        shutil.copy(f"/tmp/yedek/{f}", "/kaggle/working/cikti/")
sh("du -sh /kaggle/working/cikti/* | sort -h | tail")
print("BİTTİ", flush=True)
