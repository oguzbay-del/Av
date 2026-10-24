# Kaggle betiği (GPU'suz, internet açık): kuş bulucu ince ayar verisini (Open Images V7 + COCO 2017 kuş kutuları)
# indirir, COCO biçimine çevirir ve eğitim betiğinin kullanacağı tek arşivi üretir: /kaggle/working/veri.tar.
# Gönderim: kaggle kernels push -p tools/kus_bulucu/kaggle/veri   (ayrıntı: tools/kus_bulucu/veri.py)
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
sh("pip install -q pillow")
os.environ["VERI"] = "/tmp/veri"
sh(f"{sys.executable} /tmp/Av/tools/kus_bulucu/veri.py")
# Sıkıştırmasız tar: JPEG zaten sıkıştırılmış; açması hızlı. Ham CSV'ler arşive girmez.
sh("tar -C /tmp/veri -cf /kaggle/working/veri.tar images annotations kunye.json kunye.csv.gz"
   " && cp /tmp/veri/kunye.json /tmp/veri/kunye.csv.gz /kaggle/working/ && ls -la /kaggle/working")
print("BİTTİ", flush=True)
