# Av Haritası — çevrim içi yedek kuş tanıma (HF Space, yalnızca CPU)
FROM python:3.11-slim

# soundfile için libsndfile tekerlekle gelir; ek sistem paketi gerekmez.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    TF_CPP_MIN_LOG_LEVEL=2

# HF Spaces kapsayıcıyı uid 1000 ile çalıştırır.
RUN useradd -m -u 1000 user
USER user
ENV HOME=/home/user PATH=/home/user/.local/bin:$PATH \
    HF_HOME=/home/user/.cache/huggingface \
    TFHUB_CACHE_DIR=/home/user/.cache/tfhub
WORKDIR /home/user/app

COPY --chown=user requirements.txt .
RUN pip install --user -r requirements.txt

COPY --chown=user app.py turler.json ./
# Modelleri derleme sırasında indir, metin gömmelerini hesapla (soğuk açılış kısa olsun).
RUN python app.py

EXPOSE 7860
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860", "--no-access-log"]
