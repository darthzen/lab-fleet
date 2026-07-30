# 08 — Documentation indexers (CronJobs)

Single-file Python service (source recovered from the running image after the
original Dockerfile was lost — see Dockerfile header). Indexes the
kubernetes/website docs into Milvus with deterministic chunk IDs, per-file
content hashing, and upstream-deletion handling, so re-runs are idempotent
and incremental. Embeddings: `nomic-embed-text` via Ollama (768-dim — must
match the rest of the RAG stack, including the query side in
`09-mcp/docs-rag/`, or similarity scores are meaningless). State manifest
persists on the `k8s-docs-indexer-state` PVC between runs.

Build, import into k3s containerd, apply. The tag is `localhost/...` and the
pod uses `imagePullPolicy: Never` — the image only ever exists in the node's
containerd, never in a registry:

    docker build -t localhost/k8s-docs-indexer:v2 .
    docker save localhost/k8s-docs-indexer:v2 | sudo k3s ctr -n k8s.io images import -
    kubectl apply -f k8s-docs-indexer.yaml

## The other two corpora

| CronJob | Schedule (Sun) | Collection | Image | Entrypoint |
|---|---|---|---|---|
| `k8s-docs-indexer` | 03:00 | `k8s_docs` | `localhost/k8s-docs-indexer:v2` | baked into image |
| `suse-docs-indexer` | 04:00 | `suse_docs` | same image | `suse-docs-indexer-script` ConfigMap |
| `logicpro-docs-indexer` | 05:00 | `logicpro_docs` | `registry.suse.com/bci/python:3.12` | `logicpro-docs-indexer-script` ConfigMap |

`suse-docs-indexer` reuses the built image but runs a mounted script instead of
the built-in one, over 12 SUSE/openSUSE repos in DocBook XML and AsciiDoc — hence
the bigger work volume (8Gi) and 4h deadline. `logicpro-docs-indexer` skips the
built image entirely: it runs on the stock SUSE python base and pip-installs
`pdfplumber` into an emptyDir at start, so there is nothing to build or import.

Keeping the entrypoints in ConfigMaps means iterating a script needs only
`kubectl apply` plus a manual job trigger, with no rebuild/import cycle on the
node. Each indexer has its own 1Gi state PVC for the content-hash manifest;
losing it forces a full re-embed of that corpus.

All three embed through **ollama-exporter's pass-through proxy** on 9401 rather
than hitting Ollama on 11434 directly, so batch embedding load shows up in the
exporter's metrics — see `04-ollama/ollama-exporter/`.

History note: v2 fixed an EBUSY crash — /work is an emptyDir mount, so the
job must clear its contents and clone into a subdir instead of rmtree'ing
the mount point itself.
