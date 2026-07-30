# 09 — MCP Layer

    kubectl apply -f k8s-mcp-server.yaml            # includes its read-only RBAC
    kubectl create secret generic github-mcp-token -n ai --from-literal=token=<PAT>   # see .example file
    kubectl apply -f github-mcp-server.yaml
    kubectl create secret generic fossa-mcp-token -n ai --from-literal=token=<FOSSA-TOKEN>  # see .example file
    kubectl apply -f fossa-mcp.yaml                 # needs the image imported first, below
    kubectl apply -f docs-rag/docs-rag-mcp.yaml     # see docs-rag/README.md
    kubectl apply -f mcpo.yaml

mcpo bridges MCP servers into Open WebUI as OpenAPI tools. Config points at the
in-cluster k8s MCP server, the docs-rag MCP server, and a systemd MCP on the host
(a raw IP — it runs on the node, not in the cluster). The mcpo `--api-key` in the
manifest is a placeholder — rotate it if the service ever leaves the trusted LAN.

`k8s-mcp-server.yaml` ships the ServiceAccount plus a cluster-scoped
ClusterRole/Binding limited to `get`/`list`/`watch`. That RBAC — not the
container's `--read-only` flag — is what actually makes the server read-only, so
keep the verbs as they are.

`fossa-mcp` is read-only software-composition-analysis access to FOSSA (projects,
revisions, dependencies, licensing/vulnerability/quality issues, attribution
reports — nine tools, none of which mutate FOSSA state). Own repo:
iCloud `Developer/fossa-mcp`, Apache-2.0, unofficial. Image lives in the
in-cluster Harbor like ollama-exporter, so it needs the `harbor-pull`
imagePullSecret (created out-of-band, not in this repo):

    cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Developer/fossa-mcp
    docker build -t registry.ash4d.com/ash4d-lab/fossa-mcp:0.1.0 .
    docker push registry.ash4d.com/ash4d-lab/fossa-mcp:0.1.0
    kubectl -n ai rollout restart deploy/fossa-mcp

0.1.0 was built without a local Docker, using a throwaway rootless BuildKit pod
in `ai` that pushed straight to Harbor — `kubectl cp` the build context into
`/workspace/src`, then `buildctl build --output type=image,...,push=true`. Useful
if you ever need to rebuild from a machine with no container runtime.

The single `FOSSA_API_TOKEN` in the Secret is the *only* access control: the
server does not authenticate callers, so anything that can reach the ClusterIP
inherits that token's full read access across the FOSSA org. Keep it ClusterIP —
no ingress, no LoadBalancer — and if it ever needs to leave the namespace, put an
authenticating proxy in front of it. It binds `0.0.0.0` in-pod only because
127.0.0.1 would be unreachable through the Service; see the project's
DECISIONS.md §2.

To surface it in Open WebUI, add it to the `mcpo-config` ConfigMap in `mcpo.yaml`
alongside the others and bump `config-revision`:

    "fossa": { "type": "streamable-http",
               "url": "http://fossa-mcp.ai.svc.cluster.local:8080/mcp" }

`docs-rag/` replaces the old `retrieval-tool` FastAPI service, which is gone from
the cluster: same Milvus-backed retrieval, but streamable-HTTP MCP instead of
OpenAPI, so external Claude/Cowork sessions can use it directly as well as
through mcpo. Companion repo: darthzen/ollama-code-mcp (Claude Code
→ Ollama delegation; runs stdio on the client, no cluster deployment needed).
