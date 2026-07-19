# Fleet Wiring — Handoff / Resume Notes

Turning `lab-fleet` from published reference config into **GitOps that Rancher
Fleet deploys** to this cluster. Full plan (private): Cowork workspace
`_portfolio/ash4d-lab/fleet-wiring-plan.md`. This file is the short resume note
for picking the work back up.

## Topology

- **Rancher controller** — `v2.14.2` at `https://rancher.ash4d.com`
  (**192.168.7.148**, separate host). GitRepo/Bundle objects live here.
- **This cluster** — `sdf1`, downstream `c-nnzn9` at **192.168.7.149**.
  `fleet-agent v0.15.2` is Ready but idle — no GitRepo targets it yet.
- Deploy source is **`lab-fleet` directly**, not `ash4d.com/lab` (Fleet doesn't
  init git submodules, so a GitRepo on `ash4d.com` would clone an empty gitlink).
  Public repo → no clone secret needed.

## ✅ Phase 1 — DONE (committed to `main`, not yet pushed)

Every deployable numbered dir has a `fleet.yaml`:

- **Helm bundles** (`takeOwnership: true`, versions pinned to the running
  releases so Fleet adopts instead of upgrading):
  metallb `0.16.1`, longhorn `1.12.0`, nvdp `0.19.2`, dcgm-exporter `4.8.2`,
  ollama `1.67.0` (confirmed live), open-webui `14.8.0`, milvus `5.0.22`.
- **Raw-manifest bundles:** comfyui, indexer, mcp, hermes, emby, node-red,
  resilio, plus metallb pools, the nvidia RuntimeClass, and attu.
- Where a dir had a chart **and** raw manifests, the raw manifests were moved
  into a sibling subdir so each chart owns its own bundle path (Fleet = one
  chart per path): `01-networking/pools/`, `03-gpu/{dcgm-exporter,runtimeclass}/`,
  `06-milvus/attu/`.
- `09-mcp/github-mcp-token.secret.example.yaml` → `.yaml.txt` so Fleet never
  applies the placeholder Secret.
- `00-host` and `14-cluster-mgmt` stay docs-only (no `fleet.yaml`). Traefik is
  k3s-bundled and not Fleet-managed (`traefik-values.yaml` is reference only).

**Not yet pushed** — push `lab-fleet` `main` to the remote before Fleet can
clone it.

## ⏭ Phase 0 — Enable CD on the controller (needs Rancher API token for .148)

1. Mint a Rancher API token (UI: avatar → Account & API Keys → Create API Key,
   no scope), export as `RTOKEN`.
2. Check the `fleet` feature (agent env hinted `fleet=false`); enable if off:
   `PUT https://rancher.ash4d.com/v3/features/fleet -d '{"value":true}'`.
3. Confirm the cluster's Fleet workspace (likely `fleet-default`) and a stable
   target label (e.g. `management.cattle.io/cluster-name: c-nnzn9`).
- **Acceptance:** `GET /v1/fleet.cattle.io.gitrepos` returns 200 and the cluster
  is listed under a Fleet workspace with a targetable label.

## ⏭ Phase 2/3 — GitRepo + staged rollout (needs token; approve each widen)

Create a GitRepo in the Fleet workspace pointing at
`https://github.com/darthzen/lab-fleet`, branch `main`. **Start narrow** with a
single low-risk `paths:` entry, then widen one component at a time, riskiest
last:

| Order | Component(s) | Risk | Note |
|---|---|---|---|
| 1 | `12-node-red`, `13-resilio`, `11-emby` | low | app layer, easy rollback |
| 2 | `07-comfyui`, `09-mcp`, `10-hermes` | low–med | Secrets must pre-exist |
| 3 | `05-open-webui`, `06-milvus`, `04-ollama` | med | helm adopt; watch pod churn |
| 4 | `01-networking`, `03-gpu` | med–high | MetalLB/Traefik + GPU; net blips |
| 5 | `02-longhorn` | **high** | storage — adopt last, or monitor-only |

At each step: add the path, let Fleet render, confirm the BundleDeployment goes
Ready, spot-check the workload, proceed. Roll back by removing the path.

## Watch-outs

- **Helm adoption is the real hazard.** `helm get manifest` vs `helm template`
  should match before enabling a helm path; adopt one release at a time.
- **Missing Secrets = stuck bundles.** Raw manifests use `secretKeyRef`
  (github-mcp token, open-webui `WEBUI_SECRET_KEY`, hermes Slack/API). Create
  them out-of-band before adding those paths.
- Verify: controller `…/gitrepos/fleet-default/lab-fleet | jq .status.summary`;
  downstream `kubectl -n cattle-fleet-system get bundledeployments -A`.
