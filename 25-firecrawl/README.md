# 25 — Firecrawl (self-hosted crawl / scrape API)

Turns a URL into LLM-ready markdown. Self-hosted so crawls run on lab hardware
and lab egress instead of through firecrawl.dev, and so hermes-agent in-cluster
and hermes on the laptop share one backend.

| | |
|---|---|
| Namespace | `firecrawl` |
| Source | [firecrawl/firecrawl](https://github.com/firecrawl/firecrawl), `examples/kubernetes/cluster-install`, adapted |
| Version | `2.11.227` (== `latest` on 2026-08-24, digest-confirmed) |
| Fleet GitRepo | `lab-firecrawl` — see `../14-cluster-mgmt/gitrepos/` |
| Exposure | `firecrawl.ash4d.com` via Traefik + `letsencrypt-dns`, **unauthenticated** |
| Persistence | none — see *Why there is no PVC* |

## Objects

| File | What it creates |
|---|---|
| `configmap.yaml` | `firecrawl-config` — shared env for api, worker, nuq-worker |
| `redis.yaml` | Deployment + Service `redis` — rate limits and caches |
| `nuq-postgres.yaml` | Deployment + Service `nuq-postgres` — the job queue |
| `playwright-service.yaml` | ConfigMap + Deployment + Service — headless Chromium |
| `api.yaml` | Deployment + Service `api` — the HTTP surface, port 3002 |
| `worker.yaml` | Deployment `worker` — crawl orchestration (no Service) |
| `nuq-worker.yaml` | Deployment `nuq-worker` — does the scraping (no Service) |
| `ingress.yaml` | Ingress `firecrawl` — `firecrawl.ash4d.com` → `api:3002` |
| `nuq-postgres.secret.example.yaml.txt` | template only, never applied |

## Prerequisites

Both must be satisfied **before** the path is added to `lab-firecrawl`.

**1. The Postgres Secret.** Four Deployments read it; without it they sit in
`CreateContainerConfigError`.

```bash
kubectl --context sdf1 create namespace firecrawl
kubectl --context sdf1 -n firecrawl create secret generic firecrawl-nuq-postgres \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 24)"
```

**2. DNS.** `firecrawl.ash4d.com` → `192.168.7.150` (the shared Traefik VIP).
It was `NXDOMAIN` on 2026-08-24. cert-manager's DNS-01 challenge does not need
the A record, so a missing record presents as "certificate issued fine, nothing
connects", not as a TLS error.

## Install

Fleet renders this path; there is no `helm install` equivalent. To exercise it
by hand before handing it to Fleet:

```bash
kubectl --context sdf1 -n firecrawl apply -f 25-firecrawl/ --dry-run=server
```

Then adopt through Fleet:

```bash
kubectl --context rancher apply -f 14-cluster-mgmt/gitrepos/lab-firecrawl.yaml
```

## Verify

```bash
kubectl --context sdf1 -n firecrawl get pods
kubectl --context sdf1 -n firecrawl rollout status deploy/api

# readiness, from inside the cluster
kubectl --context sdf1 -n firecrawl exec deploy/api -- \
  curl -sf localhost:3002/v0/health/readiness

# a real scrape, end to end — proves the playwright path, which is the part
# most likely to be silently broken
kubectl --context sdf1 -n firecrawl exec deploy/api -- curl -sf \
  -X POST localhost:3002/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"],"timeout":60000}'
```

A `success: true` with markdown means the whole chain works. A `success: true`
with *empty or fetch-quality* markdown on a JS-heavy page means the request
never reached Playwright — check `PLAYWRIGHT_MICROSERVICE_URL` still ends in
`/scrape`.

## Clients

**hermes-agent, in-cluster** — set `FIRECRAWL_API_URL` to
`http://api.firecrawl.svc.cluster.local:3002`. Leave `FIRECRAWL_API_KEY` unset;
the provider accepts either one (`plugins/web/firecrawl/provider.py`,
`_get_direct_firecrawl_config`), and there is no key to give it.

**hermes on the laptop** — `FIRECRAWL_API_URL=https://firecrawl.ash4d.com`,
again with no key. Requires the DNS record above and LAN reachability.

## Departures from upstream's example

Four, each also annotated at the file it affects.

**1. `PLAYWRIGHT_MICROSERVICE_URL` ends in `/scrape`.** Upstream's k8s ConfigMap
omits the path; their compose file includes it. The API POSTs to the value
verbatim —
`apps/api/src/scraper/scrapeURL/engines/playwright/index.ts` calls `robustFetch`
with `url: config.PLAYWRIGHT_MICROSERVICE_URL` and appends nothing. With the
bare host every scrape POSTs to `/`, 404s, and falls back to plain `fetch`: no
JS rendering, no error anyone would notice. Read from source at 2.11.227.

**2. Images pinned.** Upstream uses `:latest` for all three. `firecrawl` has
semver tags, so it pins to `2.11.227`. `playwright-service` and `nuq-postgres`
publish **only** `:latest`, so they pin by digest. Re-resolve them with:

```bash
img=firecrawl/playwright-service   # or firecrawl/nuq-postgres
tok=$(curl -s "https://ghcr.io/token?scope=repository:$img:pull&service=ghcr.io" | jq -r .token)
curl -sI -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://ghcr.io/v2/$img/manifests/latest" | grep -i docker-content-digest
```

**3. Right-sized.** Upstream asks for roughly 22Gi of memory *requests* and runs
five `nuq-worker` replicas. sdf1 carries 109 other pods. Arithmetic below.

**4. No placeholder Secret, no `imagePullSecrets`.** Upstream's `secret.yaml` is
nine empty keys for cloud features this deployment does not use, and all three
images are public on ghcr.io. The one real secret — the Postgres password — is
seeded out of band, matching `buzz-relay`, `karakeep` and
`tunnel-client-credentials`.

## Resource footprint

Measured against sdf1 on 2026-08-24: 16 CPU, 64Gi, 109 pods already resident,
requesting 9740m / 18854Mi and limited to 39850m / 56098Mi.

| Component | CPU req | Mem req | CPU limit | Mem limit |
|---|---|---|---|---|
| api | 500m | 1Gi | 2000m | 3Gi |
| worker | 250m | 512Mi | 1500m | 2Gi |
| nuq-worker ×1 | 250m | 512Mi | 1500m | 2Gi |
| playwright-service | 250m | 512Mi | 2000m | 2Gi |
| nuq-postgres | 100m | 256Mi | 1000m | 1Gi |
| redis | 50m | 64Mi | 500m | 256Mi |
| **total** | **1400m** | **2880Mi** | **8500m** | **10496Mi** |

Requests are what the scheduler enforces: the node goes from 60% → **70% CPU**
and 29% → **34% memory** requested. Both fine.

Limits are the number worth knowing about. Node memory limits go from 87% →
**104% of capacity**. That is overcommit, which Kubernetes permits and this node
already practises — `catalis` alone is limited to 10Gi and `emby` to 8Gi, and
neither sits near it. Nothing here is scheduled against limits. The exposure is
that if enough workloads approach their ceilings simultaneously the node OOMs,
and Firecrawl adds 10Gi of ceiling to that pile. If that becomes uncomfortable,
`api` is the one to trim: drop its limit to 2Gi and `--max-old-space-size` to
1280 in the same edit — the two must move together, because a heap ceiling above
the cgroup limit converts a garbage collection into an OOMKill.

## Why there is no PVC

Nothing here holds data worth keeping. Postgres holds queue state (jobs in
flight), Redis holds counters and caches, and crawl *results* are returned to
the caller rather than stored. Losing the lot costs whatever was mid-crawl.
Upstream's own example makes the same call. Swapping the `nuq-postgres`
`emptyDir` for a 10Gi Longhorn PVC is a one-line change if that judgement
changes; nothing else needs to move.

## Security posture

- **The API is unauthenticated.** `USE_DB_AUTHENTICATION=false` is the only
  supported self-host mode — there is no API key to enable. The Ingress puts it
  on the LAN, so anything on `192.168.7.0/24` can spend lab CPU and lab egress.
- **Do not add this host to `23-cloudflare-tunnel`.** Public plus
  unauthenticated plus "fetch this URL for me" is an open SSRF proxy for whoever
  finds it.
- **It cannot reach the rest of the lab.** `ALLOW_LOCAL_WEBHOOKS=false` makes
  `assertSafeTargetUrl()` in the playwright service reject any URL resolving to
  a private IP, which is also what stops the LAN exposure from being a pivot.
  Consequence worth knowing: **Firecrawl cannot crawl `*.ash4d.com` names that
  resolve to `192.168.7.150`.** Flipping that flag removes the guard entirely;
  there is no allowlist mode.
- **No NetworkPolicy.** Consistent with every namespace here except
  `19-nemoclaw`. If one is ever added, this workload needs unrestricted egress
  to the internet by definition, so the useful policy is on *ingress* to
  `api:3002` and on egress *away from* RFC1918.

## Ollama

Firecrawl's AI-backed features (`json` format, `extract`, LLM-assisted parsing)
are off — no model provider is configured. `configmap.yaml` carries the two
commented lines that point them at `ollama-exporter.ai.svc.cluster.local:9401`,
the same metered proxy `18-lab-memory` and `09-mcp/ollama-code` use. The model
name must be a tag that exists on the server (`04-ollama/values.yaml`,
`models.create`) or every AI call fails model-not-found — the mistake
`09-mcp/ollama-code` already made once.
