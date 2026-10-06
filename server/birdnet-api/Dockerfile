FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg libsndfile1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Model dosyalarını imaj oluşturulurken indir (ilk istek beklemesin)
RUN python -c "from birdnetlib.analyzer import Analyzer; Analyzer()"
COPY app.py .
# Hugging Face Spaces 7860 portunu bekler
EXPOSE 7860
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860"]
