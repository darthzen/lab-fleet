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
- At the start of this work there was a second GitRepo,
  `fleet-default/ash4d-site` → `https://github.com/darthzen/ash4d.com`,
  `paths: ["deploy"]`, target `site=ash4d`, which resolved to the junk
  `cluster-ee8f7993b3a6` rather than `c-nnzn9`. Both it and its bundle were gone
  later the same session (not removed as part of this work) and the junk cluster
  has since been deleted — see the cleanup note below. **`c-nnzn9` is now the only
  Fleet-managed downstream**, alongside `fleet-local/local`.

**Target label for this cluster:** `c-nnzn9` already carries a bespoke
`ash4d-lab: ""` label — use that rather than
`management.cattle.io/cluster-name`, which is Rancher-managed. (The old
`site=ash4d` selector belonged to the deleted junk cluster; do not reuse it.)

```yaml
targets:
  - clusterSelector:
      matchLabels:
        ash4d-lab: ""
```

## ✅ RESOLVED — fleet-agent registration (was blocking everything)

Found 2026-07-29 while applying the first GitRepo, **fixed the same day** with
Option A below. Symptom: bundles reached `WaitApplied` and sat there, with the
BundleDeployment getting no status at all, because the downstream agent never
picked it up.

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

**Option A was applied 2026-07-29.** Note the original value was `""` (empty,
inheriting `default: strict`), so the exact rollback is `value: ""` — not
`"strict"`:

```bash
kubectl --context rancher patch settings.management.cattle.io agent-tls-mode \
  --type=merge -p '{"value":""}'
```

What happened after the patch: Rancher deleted and recreated the fleet-agent
Deployment, the new pod waited out the previous leader lease (~30s), then
registered — creating the `fleet-agent` Secret and populating
`status.agent.lastSeen`. `c-nnzn9` went to 2/2 bundles ready. Total time about
two minutes; **no workload on sdf1 was touched.**

One prediction that did **not** hold: the other downstream
(`cluster-ee8f7993b3a6`) last checked in 2026-07-17 and was still stuck there
afterwards, so its staleness is a separate problem — most likely that host being
offline, not TLS mode. Worth a look, but unrelated to this cluster.

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

## Controller cleanup

`2026-07-29` — deleted the Fleet cluster `cluster-ee8f7993b3a6`. It was a
**self-registered** Fleet cluster (label `fleet.cattle.io/created-by-agent-pod`),
not Rancher-managed: `clusters.management.cattle.io` only ever listed `c-nnzn9`
(sdf1) and `local`. Its agent last checked in 2026-07-17 and did not recover after
the `agent-tls-mode` fix, so the host is presumed gone.

Its cluster namespace held nothing but its own fleet-agent BundleDeployment and a
registration ServiceAccount/token; deleting the Cluster cascaded both away and the
namespace terminated cleanly. No leftover clusterregistrations — the only ones
remaining belong to `c-nnzn9`. sdf1 and `lab-node-red` were unaffected (verified:
same node-red pod UID, 0 restarts, bundle still 1/1).

If that host ever comes back online its agent will re-register and reappear as a
new self-registered cluster. To prevent that, uninstall fleet-agent from the host
itself — deleting the Cluster object here does not touch it.

## Adoption log

`2026-07-29` — **`lab-emby`, `lab-resilio`, `lab-hermes` adopted.** All four
namespaces now Fleet-managed; every BundleDeployment reports
`ready=true, nonModified=true`.

`lab-emby` and `lab-resilio` were clean no-ops on the same evidence as node-red
below: identical pod UIDs and startTimes, restart counts unchanged (emby 2,
resilio 13), rollout revisions unchanged, no new ReplicaSets, `kubectl diff`
clean. Only `metadata.generation` moved (4→5 and 2→3).

### `lab-hermes` needed a manual step first — read this before adopting anything else

Adoption failed outright at first, with Fleet stuck in `ErrApplied`:

```
cannot patch "hermes-agent" with kind Deployment: Deployment.apps "hermes-agent"
is invalid: spec.template.spec.containers[1].env[4].valueFrom: Invalid value: "":
may not be specified when `value` is not empty
```

**Cause.** The repo converts `HERMES_WEBUI_PASSWORD` from an inline `value:` to a
`secretKeyRef`. Kubernetes merges `env` lists **by `name`**, so Helm's
strategic-merge patch laid `valueFrom` *on top of* the live `value` instead of
replacing it, and the API server rejects an env var carrying both. Helm could not
emit a directive to delete the live `value`, because the object was not yet
Helm-owned — there was no prior release manifest to diff against. It retried
~16 times, burning Helm revisions, and never touched the Deployment.

**Fix.** Make live match the repo *before* letting Fleet adopt it. A client-side
`kubectl apply` can do what Helm could not, because the live object carried
`kubectl.kubernetes.io/last-applied-configuration` containing the inline value,
which gives `apply` the third input it needs for a proper 3-way merge:

```bash
kubectl apply -f 10-hermes/hermes.yaml     # removes value:, adds valueFrom:
kubectl -n hermes rollout status deploy/hermes-agent --timeout=300s
kubectl --context rancher -n fleet-default patch gitrepo lab-hermes \
  --type=merge -p '{"spec":{"forceSyncGeneration":1}}'
```

Fleet then adopted it immediately. The pod restarted once — expected, since this
*is* a pod template change — and came back with both containers ready, the
credential unchanged (the Secret was seeded from the live value), Deployment at
revision 13, and `kubectl diff` finally clean: the repo's one intentional
divergence is now resolved on the cluster too.

**Generalisation.** Fleet/Helm adoption cannot remove a field that exists on a
live object but not in the repo, when the field is inside a list merged by key and
the object is not yet Helm-owned. Any such divergence must be pre-applied by hand.
Checked the remaining namespaces for the same pattern: **none of them have it**,
because every other manifest was reconciled to match live exactly. hermes was the
only intentional divergence in the repo, and it is now closed.

`2026-07-29` — **`lab-node-red` adopted. Verified no-op.** First namespace on
Fleet. Evidence, before vs after:

| Check | Before | After |
|---|---|---|
| Pod name / UID | `node-red-fbdd4f8fd-q2jbt` / `42e62d04…` | **identical** |
| Pod startTime | 2026-07-20T18:49:13Z | **identical** (never restarted) |
| Restart count | 0 | **0** |
| ReplicaSets | `node-red-fbdd4f8fd` only | **same one only** |
| Rollout revision | 1 | **1** (no new rollout) |
| `kubectl diff` vs repo | clean | **clean** |
| Helm ownership | none | `release=lab-node-red-12-node-red` |
| BundleDeployment | — | `ready=true`, `nonModified=true` |

`metadata.generation` did go 2 → 3, which normally indicates a spec write. It was
Helm rewriting the spec to identical values: the pod-template hash is unchanged,
no second ReplicaSet was created, rollout history stayed at revision 1, and the
pod is the original one from ten days earlier. So the bump is real but inert —
expect it on every adopted Deployment, and do not read it as a restart.

Remaining namespaces, in order: `lab-ai` (eight paths, one at a time),
`lab-metallb-system`, `lab-nvidia-device-plugin`,
`lab-cattle-monitoring-system`, then `lab-longhorn-system` last.

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
