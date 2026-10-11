# Kaggle betiği (GPU'suz, internet açık): iNaturalist fotoğraflarını indirir ve eğitim betiğinin
# kullanacağı tek arşivi üretir: /kaggle/working/veri.tar. GPU kotası harcamaz.
# Gönderim: kaggle kernels push -p tools/kus_foto/kaggle/veri
import os
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


sh(f"rm -rf /tmp/Av && git clone -q --depth 1 -b {DAL} https://github.com/oguzbay-del/Av /tmp/Av")
sh("pip install -q requests pillow")
os.environ.update({"VERI": "/tmp/veri", "YEDEK": "/tmp/yedek", "YEDEK_VERI": "0", "DEPO": "/tmp/Av"})
sh(f"{sys.executable} /tmp/Av/tools/kus_foto/kus_foto.py indir")
# Sıkıştırmasız tar: JPEG zaten sıkıştırılmış; açması hızlı
sh("tar -C /tmp/veri -cf /kaggle/working/veri.tar meta foto && ls -la /kaggle/working/veri.tar")
print("BİTTİ", flush=True)
