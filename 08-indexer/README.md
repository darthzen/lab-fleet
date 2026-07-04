# 08 — k8s-docs-indexer (CronJob)

Single-file Python service (source recovered from the running image after the
original Dockerfile was lost — see Dockerfile header). Indexes the
kubernetes/website docs into Milvus with deterministic chunk IDs, per-file
content hashing, and upstream-deletion handling, so re-runs are idempotent
and incremental. Embeddings: `nomic-embed-text` via Ollama (768-dim — must
match the rest of the RAG stack). State manifest persists on the
`k8s-docs-indexer-state` PVC between runs.

Build, import into k3s containerd, apply:

    docker build -t k8s-docs-indexer:latest .
    docker save k8s-docs-indexer:latest | sudo k3s ctr -n k8s.io images import -
    kubectl apply -f k8s-docs-indexer.yaml

History note: v2 fixed an EBUSY crash — /work is an emptyDir mount, so the
job must clear its contents and clone into a subdir instead of rmtree'ing
the mount point itself.
