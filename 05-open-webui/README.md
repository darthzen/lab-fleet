# 05 — Open WebUI

    helm repo add open-webui https://helm.openwebui.com/
    helm upgrade --install open-webui open-webui/open-webui -n ai -f values.yaml

Embedded Ollama disabled — points at the shared Ollama service. RAG wired to
Milvus (`VECTOR_DB=milvus`) with `nomic-embed-text` embeddings via Ollama.
