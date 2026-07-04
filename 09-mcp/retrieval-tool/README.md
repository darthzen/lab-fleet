# retrieval-tool — multi-source semantic search (FastAPI)

Single-file FastAPI service over Milvus (source recovered from the running
image). Exposed through mcpo into Open WebUI as OpenAPI tools:
`GET /sources`, `POST /search` (one source), `POST /search_all` (fan-out,
merged + ranked). GPU-light by design: nomic-embed-text embeddings via
Ollama, CPU vector search in Milvus — the big chat model never runs during
retrieval. Sources are env-configurable (`name:collection,...`), so new
collections (distro docs, codebases) need no code change.

    docker build -t localhost/retrieval-tool:v1 .
    docker save localhost/retrieval-tool:v1 | sudo k3s ctr -n k8s.io images import -
    kubectl apply -f retrieval-tool.yaml
