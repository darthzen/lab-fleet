# docs-rag-mcp — semantic search over the lab's cached doc corpora (MCP)

Streamable-HTTP MCP server over the Milvus collections that the `08-indexer`
CronJobs populate: `k8s_docs` (kubernetes/website), `suse_docs` (12 SUSE /
openSUSE repos), `logicpro_docs`. Two tools — `docs_search` and
`docs_list_sources` — returning markdown with real upstream URLs, so results are
citable rather than repo-relative paths the user cannot open.

GPU-light by design: `nomic-embed-text` query embeddings via Ollama, CPU vector
search in Milvus, so the big chat model never runs during retrieval. Query
embeddings must use the same model the indexers embedded with (768-dim) or the
similarity scores are meaningless.

Reached three ways: mcpo proxies it into Open WebUI as OpenAPI tools, the
LoadBalancer service (`192.168.7.159:8080`) serves `/mcp` to Claude/Cowork
sessions outside the cluster, and in-cluster clients use the ClusterIP name.

Supersedes the old `retrieval-tool` FastAPI service (OpenAPI, `/search` +
`/search_all`), which no longer exists on the cluster.

`server.py` ships as the `docs-rag-mcp-src` ConfigMap inside
`docs-rag-mcp.yaml`. The v2 image bakes it in, so the ConfigMap is not mounted —
it is the versioned source of record for the next build:

    kubectl -n ai get cm docs-rag-mcp-src -o jsonpath='{.data.server\.py}' > server.py
    docker build -t localhost/docs-rag-mcp:v2 .
    docker save localhost/docs-rag-mcp:v2 | sudo k3s ctr -n k8s.io images import -
    kubectl -n ai rollout restart deploy/docs-rag-mcp
