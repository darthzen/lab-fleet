# Recovered from image history (k8s-docs-indexer:v2) after the original
# Dockerfile was lost. python:3.12-slim base, git for the docs clone.
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /app
COPY index_k8s_docs.py /app/index_k8s_docs.py
RUN mkdir -p /work /state

ENTRYPOINT ["python3", "/app/index_k8s_docs.py"]
