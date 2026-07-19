# 06 — Milvus (standalone) + Attu

    helm repo add milvus https://zilliztech.github.io/milvus-helm/
    helm upgrade --install milvus milvus/milvus -n ai -f values.yaml
    kubectl apply -f attu/attu.yaml

Standalone mode (no Pulsar), single etcd replica, MinIO standalone — sized for
a single-node lab. Attu provides the admin UI over the Milvus gRPC port. It
lives in `attu/` as its own Fleet bundle, separate from the Milvus Helm release.
