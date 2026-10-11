# CUDA 12 + cuDNN 9, as required by CTranslate2 4.x (faster-whisper's backend).
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python

WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir -r requirements.txt

# Bake the model into the image (not under /models, which Vertex mounts over) so replicas don't download ~1.6 GB on every cold start.
RUN python -c "from faster_whisper import download_model; download_model('large-v3-turbo', output_dir='/opt/whisper-model')"

COPY server.py stream_server.py vocab.py ./
ENV AIP_HTTP_PORT=8080
EXPOSE 8080
CMD ["sh", "-c", "python -m uvicorn server:app --host 0.0.0.0 --port ${AIP_HTTP_PORT}"]
