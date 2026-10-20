# Av Haritası — çevrim içi yedek kuş tanıma (Google Cloud Run, yalnızca CPU)
FROM python:3.11-slim

# soundfile için libsndfile tekerlekle gelir; ek sistem paketi gerekmez.
# PIP_NO_CACHE_DIR: pip önbelleği imaja girmesin (imaj küçük kalsın).
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 TF_CPP_MIN_LOG_LEVEL=2

# Kök olmayan kullanıcıyla çalış.
RUN useradd -m -u 1000 user
USER user
ENV HOME=/home/user PATH=/home/user/.local/bin:$PATH \
    HF_HOME=/home/user/.cache/huggingface \
    TFHUB_CACHE_DIR=/home/user/.cache/tfhub
WORKDIR /home/user/app

# requirements.txt yalnızca CPU tekerleklerini (PyTorch CPU dizini) çeker.
COPY --chown=user requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

COPY --chown=user app.py geribildirim.py turler.json ./
# Modelleri derleme sırasında indir, metin gömmelerini hesapla: çalışma anında
# hiçbir şey indirilmez, soğuk açılışta yalnızca diskten belleğe yüklenir.
RUN python app.py --isit
# Çalışma anında Hugging Face'e sürüm sorgusu yapılmasın (açılış hızlansın).
ENV HF_HUB_OFFLINE=1

# Cloud Run dinlenecek portu PORT ortam değişkeniyle verir (varsayılan 8080).
ENV PORT=8080
EXPOSE 8080
CMD ["python", "app.py"]
