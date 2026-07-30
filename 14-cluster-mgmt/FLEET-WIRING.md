# Fleet Wiring — Handoff / Resume Notes

Turning `lab-fleet` from published reference config into **GitOps that Rancher
Fleet deploys** to this cluster. Full plan (private): Cowork workspace
`_portfolio/ash4d-lab/fleet-wiring-plan.md`. This file is the short resume note
for picking the work back up.

Verified against the live cluster **2026-07-29**.

## Topology

- **Rancher controller** — `v2.14.3` at `https://rancher.ash4d.com`
  (**192.168.7.148**, separate host). GitRepo/Bundle objects live here, and the
  local `kubectl` context named **`rancher`** already has API access to them —
  no Rancher API token needed (see Phase 0).
- **This cluster** — `sdf1`, downstream `c-nnzn9` at **192.168.7.149**.
  `fleet-agent v0.15.4`'s pod is Running, but it has **never registered** — see
  the blocker section below. Its only bundle is its own `fleet-agent-c-nnzn9`.
- Deploy source is **`lab-fleet` directly**, not `ash4d.com/lab` (Fleet doesn't
  init git submodules, so a GitRepo on `ash4d.com` would clone an empty gitlink).
  Public repo → no clone secret needed.
- Note the downstream cluster has **no Fleet CRDs** — that is normal for this
  Fleet version (`EXPERIMENTAL_COPY_RESOURCES_DOWNSTREAM=false`). Bundle state is
  read on the controller, not here. See Verify below.

## ✅ Phase 1 — DONE (committed AND pushed to `main`)

Every deployable numbered dir has a `fleet.yaml`:

- **Helm bundles** (`takeOwnership: true`, versions pinned to the running
  releases so Fleet adopts instead of upgrading):
  metallb `0.16.1`, longhorn `1.12.0`, nvdp `0.19.2`, dcgm-exporter `4.8.2`,
  ollama `1.67.0`, open-webui `14.8.0`, milvus `5.0.22`. Chart versions all match
  the running releases. Two needed values corrections — see the log below;
  comparing `helm get values` alone was **not** sufficient to catch them.
- **Raw-manifest bundles:** comfyui, the three doc indexers, mcp, hermes, emby,
  node-red, resilio, plus metallb pools, the nvidia RuntimeClass, attu,
  ollama-exporter, and docs-rag. **Every one of these also sets
  `helm.takeOwnership: true`** — Fleet deploys raw manifests through Helm
  internally, and the pre-existing objects carry no `meta.helm.sh/release-name`
  annotation, so without it the first sync fails on ownership. With it, adoption
  is metadata-only: Helm labels land on the top-level objects, pod templates are
  untouched, and nothing restarts.
- Where a dir had a chart **and** raw manifests, the raw manifests were moved
  into a sibling subdir so each chart owns its own bundle path (Fleet = one
  chart per path): `01-networking/pools/`, `03-gpu/{dcgm-exporter,runtimeclass}/`,
  `06-milvus/attu/`, `04-ollama/ollama-exporter/`.
- Placeholder/unapplied manifests are renamed `.yaml.txt` so Fleet never applies
  them: `09-mcp/github-mcp-token.secret.example.yaml.txt`,
  `10-hermes/hermes-webui.secret.example.yaml.txt`,
  `07-comfyui/comfyui-user-script.yaml.txt`.
- `00-host` and `14-cluster-mgmt` stay docs-only (no `fleet.yaml`). Traefik is
  k3s-bundled and not Fleet-managed (`traefik-values.yaml` is reference only).

## ✅ Phase 0 — Enable CD on the controller: ALREADY DONE

The earlier note here assumed the `fleet` feature was off and that a Rancher API
token was needed. Both were wrong as of 2026-07-29:

- The `fleet` feature is **enabled** (`features.management.cattle.io/fleet`:
  `spec.value` unset, `status.default: true`). Nothing to PUT.
- `kubectl --context rancher` reaches the GitRepo/Bundle/BundleDeployment CRDs
  directly, so the whole flow can be driven with `kubectl` — no `RTOKEN`, no
  `/v3/features` call.
- `c-nnzn9` is registered in workspace **`fleet-default`**.
- **Working precedent already on the controller:** GitRepo
  `fleet-default/ash4d-site` → `https://github.com/darthzen/ash4d.com`, branch
  `main`, `paths: ["deploy"]`, target `clusterSelector.matchLabels.site=ash4d`.
  It is Ready 1/1 — but it targets `cluster-ee8f7993b3a6` (a *different*
  downstream, last seen 2026-07-17), **not** `c-nnzn9`. Copy its shape, don't
  reuse its selector.

**Target label for this cluster:** `c-nnzn9` already carries a bespoke
`ash4d-lab: ""` label — use that rather than
`management.cattle.io/cluster-name`, which is Rancher-managed.

```yaml
targets:
  - clusterSelector:
      matchLabels:
        ash4d-lab: ""
```

## 🛑 BLOCKER — fleet-agent registration is broken

Found 2026-07-29 while applying the first GitRepo. **Fleet cannot deploy anything
to this cluster until this is fixed.** Bundles reach `WaitApplied` and sit there;
the BundleDeployment gets no status at all, because the downstream agent never
picks it up.

```
Failed to register agent: registration failed: cannot create clusterregistration
on management cluster ... tls: failed to verify certificate: x509: failed to load
system roots and no roots provided; open /dev/null: not a directory
```

Diagnosis — it is a policy mismatch, not a network or image problem:

| Check | Result |
|---|---|
| Agent → Rancher network | ✅ `wget https://rancher.ash4d.com/ping` returns `pong` |
| CA roots in the agent image | ✅ 435 certs in `/var/lib/ca-certificates/pem` |
| Rancher server cert | ✅ valid, public **Let's Encrypt** (`CN=YR1`, expires 2026-10-15) |
| `agent-tls-mode` (controller) | ⚠️ **`strict`** (Rancher default) |
| `apiServerCA` in `fleet-agent-bootstrap` | ❌ **empty, 0 bytes** |

`strict` mode requires an explicitly-provided CA and will not fall back to system
roots. With `apiServerCA` empty, registration can never succeed — regardless of
the fact that the cert is publicly trusted.

Two fixes:

**A — switch to the system trust store** (matches a publicly-trusted Rancher cert,
and is Rancher's supported configuration for one):

```bash
kubectl --context rancher patch settings.management.cattle.io agent-tls-mode   --type=merge -p '{"value":"system-store"}'
```

Controller-wide: it affects **every** downstream agent, not just sdf1. Agents
redeploy their bootstrap config afterwards.

**B — populate `apiServerCA`** with the Let's Encrypt chain and keep `strict`.
Scoped to this cluster, but must be redone whenever the issuing CA rotates.

A is the better fit here; B is the choice if some other downstream depends on
strict mode. **Not applied — this is a controller-wide setting on a separate
host, so it needs a deliberate call.**

Worth noting the other downstream (`cluster-ee8f7993b3a6`) last checked in
2026-07-17, the same day the Rancher cert was renewed. It may be broken for the
same reason, which would make A a fix for both.

## ⏭ Phase 2/3 — GitRepos + staged rollout (approve each widen)

**One GitRepo per namespace, named `lab-<namespace>`** — see
`gitrepos/README.md` for the full table, rollout order, and the manifests
themselves. Each namespace can be adopted, rolled back, or paused independently.

Order: `lab-node-red` → `lab-emby` / `lab-resilio` → `lab-hermes` → `lab-ai`
(eight paths, one at a time) → `lab-metallb-system` /
`lab-nvidia-device-plugin` / `lab-cattle-monitoring-system` →
`lab-longhorn-system` last.

At each step: apply (or add a path), let Fleet render, confirm the
BundleDeployment goes Ready, spot-check the workload, proceed. Roll back by
removing the path or deleting the GitRepo.

Leave `correctDrift` disabled at first. Turning it on makes Fleet revert
out-of-band `kubectl edit`s — desirable eventually, but it will fight the
hand-tuning habits this cluster has (see the ComfyUI and Ollama notes below).

## Watch-outs

- **Helm adoption is the real hazard, and `helm get values` will not show it.**
  Two releases had drift in the *rendered objects* while their user-supplied
  values looked clean, because someone had edited the live object directly:
  open-webui's Ollama URLs and Longhorn's replica counts. Always diff
  `helm get manifest <release>` against the live cluster — not just values —
  before enabling a helm path, and adopt one release at a time:

  ```bash
  helm -n <ns> get manifest <release> > /tmp/m.yaml
  kubectl diff -n <ns> -f /tmp/m.yaml
  ```

- **Longhorn replica count is the single most dangerous default here.** The chart
  defaults to 3 replicas; this one-node cluster runs 1. Adopting Longhorn without
  `02-longhorn/values.yaml`'s `persistence.defaultClassReplicaCount: 1` would
  leave every new volume permanently Degraded. This is why Longhorn is last in
  the table above. Note the *global* default-replica-count is deliberately left
  undeclared — see the comment in that values file for why.
- **Missing Secrets = stuck bundles.** Create these before enabling the
  corresponding path:
  | Secret | Namespace | Needed by | Exists? |
  |---|---|---|---|
  | `github-mcp-token` | `ai` | github-mcp-server | ✅ |
  | `harbor-pull` | `ai` | ollama-exporter (Harbor image) | ✅ |
  | `hermes-api-key`, `hermes-slack` | `hermes` | hermes-agent | ✅ |
  | `hermes-webui` | `hermes` | hermes-webui container | ❌ **create first** |

  The earlier note here also listed `WEBUI_SECRET_KEY` for open-webui. That was
  wrong: the live StatefulSet has no `secretKeyRef` env and no `envFrom`, and no
  such Secret exists in `ai`. Nothing to create.
- **`hermes-webui` password.** The live Deployment carries
  `HERMES_WEBUI_PASSWORD` as a plaintext env value. `10-hermes/hermes.yaml`
  reads it from a Secret instead — this repo is public and Fleet renders
  manifests into a Bundle on the controller. This is the **only** intentional
  divergence between the repo and live state. Seed the Secret with the value
  already in the live spec so adoption does not change the credential (keeping it
  out of git is the requirement here, not rotating it). Note this is the one
  adopted path that **does** restart its pod, since the env moves from an inline
  value to a `secretKeyRef`.
- **ComfyUI is declared at `replicas: 0`,** matching the cluster — it pins the
  same V100 that Ollama holds. Scale it by editing the manifest, not
  `kubectl scale`, or Fleet reconciles it back.
- **Locally-built images** (`localhost/k8s-docs-indexer:v2`,
  `localhost/docs-rag-mcp:v2`) use `imagePullPolicy: Never` and exist only in
  the node's containerd. Fleet deploys the manifests; it does not build or
  distribute these images.

## Verify

Controller (this is where bundle state actually lives):

```bash
# Is the agent even registered? Empty lastSeen = the blocker above.
kubectl --context rancher -n fleet-default get cluster c-nnzn9 \
  -o jsonpath='{.status.agent.lastSeen}'

kubectl --context rancher -n fleet-default get gitrepo lab-node-red \
  -o jsonpath='{.status.display.state}|{.status.display.readyBundleDeployments}'
kubectl --context rancher get bundles -A
kubectl --context rancher -n cluster-fleet-default-c-nnzn9-eaf6ebdbb298 \
  get bundledeployments
```

A bundle stuck in `WaitApplied` with an empty BundleDeployment status means the
agent is not consuming it — check agent registration before debugging the bundle:

```bash
kubectl -n cattle-fleet-system logs deploy/fleet-agent --tail=20
```

The old note said to run `kubectl -n cattle-fleet-system get bundledeployments`
**downstream** — that fails here (`the server doesn't have a resource type
"bundledeployments"`), because this Fleet version keeps BundleDeployments on the
controller in the per-cluster namespace shown above.

## Drift reconciliation log

`2026-07-29` — full live-vs-repo audit before wiring anything. All seven Helm
releases were already exact. Raw manifests had drifted, and the repo has been
corrected to match live:

- **New to the repo:** `suse-docs-indexer` + `logicpro-docs-indexer` (CronJobs,
  ConfigMap-mounted scripts, state PVCs); `ollama-exporter` (metrics on 9400 +
  Ollama pass-through proxy on 9401); `k8s-mcp-server` ServiceAccount and
  cluster-scoped read-only RBAC; the `attu` and `hermes-agent` Ingresses;
  `comfyui-filebrowser-config` PVC.
- **`retrieval-tool` → `docs-rag`:** the FastAPI service is gone from the
  cluster, replaced by the `docs-rag-mcp` MCP server. Old dir and build inputs
  removed.
- **Helm values corrected (rendered-object drift, invisible to `helm get
  values`):** open-webui's `ollamaUrls` and `RAG_OLLAMA_BASE_URL` pointed at
  `ollama:11434` while the live StatefulSet had been edited to the exporter proxy
  on `9401`; Longhorn's `values.yaml` claimed "chart defaults" while the cluster
  runs `persistence.defaultClassReplicaCount: 1` against a chart default of 3.
  Both were verified by re-rendering `helm template` with the corrected values
  and diffing against live.
- **Corrected to match live:** ComfyUI `replicas: 1` → `0` and its V100 UUID pin
  now declared; filebrowser config emptyDir → PVC and its service port
  `8080` → `80`; `glm-model-pvc` missing `storageClassName: longhorn`; attu
  service `LoadBalancer` → `ClusterIP`; hermes gained its `hermes-webui`
  container, two init containers, `LoadBalancer` service and 8787 port;
  `k8s-docs-indexer` image/pull policy; all indexers and docs-rag now embed via
  the exporter proxy on 9401; `mcpo` config gained its `docs` entry; MetalLB
  service annotations; Emby's bogus `nvidia.com/gpu: 1` limit removed (it pins
  by UUID, and the live pod has no such request).
- **Parked, not applied:** `07-comfyui/comfyui-user-script.yaml.txt`. Added to
  the repo in `77eed5e` but never applied — there is no `comfyui-user-script`
  ConfigMap on the cluster and the live pod mounts no user script. Kept as
  reference so wiring Fleet cannot push an untested change into a GPU workload.

Every manifest was confirmed with `kubectl diff` after editing: clean except the
deliberate `hermes-webui` Secret substitution.

## Out of scope (not in this repo, running on the cluster)

These namespaces have live workloads with no `lab-fleet` bundle. They are
deliberately untracked here, not oversights — decide separately whether any
should be adopted: `lab-memory` (karakeep + MCP servers), `registry` (Harbor),
`buzz`, `trading-agent`, `nemoclaw` + `nemoclaw-sandboxes`, `openshell`,
`ollama-code`, `ash4d-origin`, `agent-sandbox-system`, `managed-agent`, and the
Rancher-managed `cattle-*` / `cert-manager` stacks.
