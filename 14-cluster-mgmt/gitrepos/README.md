# Fleet GitRepos — one per namespace

These are Fleet **`GitRepo` custom resources** (`gitrepos.fleet.cattle.io`), not
git repositories. Each one points Fleet at the existing `lab-fleet` repo and
lists which paths to render. They live on the **Rancher controller**
(192.168.7.148, kubectl context `rancher`) — not on sdf1 — so they are not part
of any bundle in this repo. Kept here as the versioned source of record.

    kubectl --context rancher apply -f 14-cluster-mgmt/gitrepos/lab-node-red.yaml

Applying any file here is a **single** adoption step, and idempotent once adopted —
no file holds more than one unadopted path (see the rule below). The exception is
`lab-ai`, which has **no file at all** and is staged by hand — see below.

> **🔴 Two corrections learned by breaking things on 2026-07-30. Read these
> before adopting anything.**
>
> **1. Removing a path does NOT roll back — it uninstalls.** For a bundle whose
> Helm release Fleet has taken ownership of, deleting the path runs the
> equivalent of `helm uninstall`. This deleted karakeep's StatefulSets,
> Deployment, Service, Ingress and one PVC. Use `spec.paused: true` to stop Fleet
> acting, and fix forward. Only `spec.paths` removal on a bundle that never
> reached ownership is safe.
>
> **2. A nested path is not a staging gate.** Fleet deploys `<path>/<child>` as
> soon as `<path>` is adopted, whether or not the child is in `spec.paths`.
> Gating only works between SIBLING paths (`01-networking` and
> `01-networking/pools`). The "then patch in the second path" note that used to
> appear on `lab-buzz`, `lab-lab-memory` and `lab-cert-manager` was wrong and has
> been corrected.
>
> **3. `kubectl diff` clean does not predict Fleet.** Fleet applies server-side
> and needs field *ownership*. Pre-flight any pre-existing Helm release with
> `kubectl apply --server-side --dry-run=server`, which surfaces the
> field-manager conflicts `kubectl diff` normalises away.
>
> Details and evidence for all three are in `FLEET-WIRING.md`.

## Convention: `lab-<namespace>`

One GitRepo per Kubernetes namespace, so each namespace's workloads can be
adopted, rolled back, or paused independently of every other.

| GitRepo | Namespace | Paths | Risk |
|---|---|---|---|
| `lab-nemoclaw` | `nemoclaw` + `nemoclaw-sandboxes` | `19-nemoclaw` | **lowest — start here.** No pod templates at all |
| `lab-node-red` | `node-red` | `12-node-red` | low |
| `lab-emby` | `emby` | `11-emby` | low |
| `lab-resilio` | `resilio` | `13-resilio` | low |
| `lab-ash4d-origin` | `ash4d-origin` | `16-ash4d-origin` | low |
| `lab-hermes` | `hermes` | `10-hermes` | low–med — needs `hermes-webui` Secret |
| `lab-ai` | `ai` | 10 paths (04→09, 21) | med — **no `.yaml` file, staged by hand — see below** |
| `lab-openshell` | `openshell` | `20-openshell` | med — **after `lab-nemoclaw`**; vendored chart |
| `lab-buzz` | `buzz` | `17-buzz` (+ nested `17-buzz/minio`, comes automatically) | med — stateful; needs `buzz-relay` Secret |
| `lab-lab-memory` | `lab-memory` | `18-lab-memory` (+ nested `/raw`) | **ADOPTED** 2026-07-30 after an SSA ownership handoff — zero pod restarts |
| `lab-metallb-system` | `metallb-system` | `01-networking` — then patch in `01-networking/pools` | med–high |
| `lab-nvidia-device-plugin` | `nvidia-device-plugin` | `03-gpu` — `03-gpu/runtimeclass` is **on hold, k3s owns it** | med–high |
| `lab-cattle-monitoring-system` | `cattle-monitoring-system` | `03-gpu/dcgm-exporter` | med |
| `lab-cert-manager` | `cert-manager` | `15-cert-manager` (+ nested `/issuer`) | **ADOPTED** 2026-07-30 after an SSA ownership handoff — owns the 6 CRDs, never delete |
| `lab-longhorn-system` | `longhorn-system` | `02-longhorn` | **highest — adopt last** |

Adopt in that order. Within `lab-ai`, add paths one at a time — raw manifests
(`08-indexer`, `09-mcp`, `07-comfyui`, `06-milvus/attu`,
`04-ollama/ollama-exporter`, `09-mcp/ollama-code`) before the Helm charts
(`04-ollama`, `05-open-webui`, `06-milvus`). `21-unsloth-studio` goes last —
it is a **fresh install, not an adoption**, so Fleet deploys it the moment the
path lands; its `unsloth-jupyter` Secret and DNS must exist first (see
`21-unsloth-studio/README.md`).

Two ordering constraints are hard, not preferences:

- **`lab-nemoclaw` before `lab-openshell`.** The openshell chart renders a
  ServiceAccount, Role, RoleBinding and NetworkPolicy *into* the
  `nemoclaw-sandboxes` namespace, and `lab-nemoclaw` is what creates that
  namespace. These two are not independently removable.
- **`lab-cert-manager` late, and never deleted.** It owns the six cert-manager
  CRDs, so deleting the GitRepo deletes every `Certificate`, `Issuer` and
  `Order` object in the cluster. Roll back by removing the path.

`lab-ash4d-origin`, `lab-nemoclaw` and `lab-openshell` hold a single path each,
so there is nothing to stage for them.

## `lab-ai` deliberately has no `.yaml` file

**There is no `lab-ai.yaml`, on purpose — do not add one.** It used to exist and
listed all eight paths. That made it a footgun: a single `kubectl apply -f` would
widen the GitRepo by however many paths were still unadopted, in one shot, which
is exactly what the one-at-a-time rule exists to prevent. A file whose whole
convention is "apply me" cannot safely hold a staged rollout, so the staging lives
here as commands instead.

Because it has no file, `lab-ai` also misses anything the files carry — notably
`pollingInterval`. It was set by hand and must be re-set if the GitRepo is ever
recreated:

```bash
kubectl --context rancher -n fleet-default patch gitrepo lab-ai --type=merge \
  -p '{"spec":{"pollingInterval":"60s"}}'
```

`spec.paths` is the only field that changes between steps, so widen by patching it
and leave everything else alone:

```bash
# Current live state — the five raw-manifest paths (adopted 2026-07-29).
# Append exactly ONE entry per step, in this order:
#   09-mcp/ollama-code → 04-ollama → 05-open-webui → 06-milvus
#     → 21-unsloth-studio (fresh install, deploys immediately — prereqs in
#       21-unsloth-studio/README.md)
kubectl --context rancher -n fleet-default patch gitrepo lab-ai --type=merge -p '{"spec":{"paths":[
  "08-indexer","09-mcp","07-comfyui","06-milvus/attu","04-ollama/ollama-exporter",
  "09-mcp/ollama-code"
]}}'
```

`09-mcp/ollama-code` is first in that order because it is the only entry that is
**not** an adoption — it moves the ollama-code MCP server out of its own
`ollama-code` namespace and into `ai`. Read `09-mcp/ollama-code/fleet.yaml`
before running it: the old Ingress must be deleted *first* so two Ingresses
never both claim `mcp-ollama.ash4d.com`, and cert-manager has to issue a fresh
`mcp-ollama-ash4d-tls` in `ai`. Full sequence in `FLEET-WIRING.md`.

Note that path lives *underneath* `09-mcp`, which is already adopted. It carries
its own `fleet.yaml` so Fleet splits it into a separate bundle instead of
folding it into `lab-ai-09-mcp` — the same mechanism that keeps
`09-mcp/docs-rag`, which has no `fleet.yaml`, folded in. After adding it, check
that `lab-ai-09-mcp`'s resource count did not change.

Verify before the next step — both must be `true`, and `helm -n ai list` should
show one new release at revision 1:

```bash
kubectl --context rancher -n cluster-fleet-default-c-nnzn9-eaf6ebdbb298 \
  get bundledeployments -o custom-columns=\
'NAME:.metadata.name,READY:.status.ready,NONMODIFIED:.status.nonModified' | grep lab-ai
```

Roll back a step by patching `spec.paths` without the entry you just added.

To recreate the GitRepo from scratch, copy a sibling file (they share every field
but `name` and `paths`), set `name: lab-ai`, and start `paths` at the five raw
entries above.

## The rule: one unadopted path per file

**A file in this dir must never contain more than one path that is not yet
adopted.** Otherwise `kubectl apply -f` widens the GitRepo by every unadopted path
at once, which is precisely what the one-at-a-time rule exists to prevent. Keeping
this invariant means applying any file here is always a single adoption step, and
always idempotent once adopted.

`lab-metallb-system.yaml` and `lab-nvidia-device-plugin.yaml` used to carry two
paths each and were trimmed to their safe first path on 2026-07-29. The second
path is documented as a patch command in each file's own header comment. Add it
only after the first is verified Ready. Every other file is single-path.

`lab-ai` is the one namespace with no file at all: it has *five* adopted paths and
four pending, and a file listing only one unadopted path would misrepresent the
five that are live. Commands above.

### `03-gpu/runtimeclass` is not just a staging question

While trimming `lab-nvidia-device-plugin.yaml` it turned out the `nvidia` and
`nvidia-experimental` RuntimeClasses are **owned by k3s**, not by this repo:

    objectset.rio.cattle.io/owner-gvk:  k3s.cattle.io/v1, Kind=Addon
    objectset.rio.cattle.io/owner-name: runtimes

They ship with k3s's bundled `runtimes` Addon and are as old as the cluster.
Adopting that path points Fleet and k3s's addon controller at the same
cluster-scoped objects; if they fight, GPU scheduling breaks for ollama, comfyui
and dcgm-exporter simultaneously. `03-gpu/runtimeclass/nvidia-runtimeclass.yaml`
also carries the `objectset.rio.cattle.io/*` annotations committed verbatim — a
symptom of the same thing.

**This is unresolved.** Decide whether the path belongs in Fleet at all before
adding it — leaving the RuntimeClasses to k3s is a legitimate answer, in which
case drop the path and note it alongside Traefik as k3s-bundled and not
Fleet-managed. It also reverses the stage order the old comment implied: the
device plugin chart is the safe first step, not the RuntimeClass.

## Where the convention doesn't map cleanly

`03-gpu` splits across two GitRepos: the device plugin lands in
`nvidia-device-plugin`, but `03-gpu/dcgm-exporter` deploys into
`cattle-monitoring-system` alongside rancher-monitoring. The cluster-scoped
`03-gpu/runtimeclass` has no namespace of its own, so it rides with
`lab-nvidia-device-plugin` — it must land before any GPU pod schedules.

## Why adoption should be a no-op

Every raw-manifest `fleet.yaml` sets `helm.takeOwnership: true`, and every Helm
`fleet.yaml` pins the chart version to the running release. The manifests were
reconciled against live state, so a first sync should only add Helm ownership
labels to the top-level objects — no pod template changes, no restarts.

The one exception was `lab-hermes`: `HERMES_WEBUI_PASSWORD` moved from an inline
value to a `secretKeyRef`, a pod template change, so that pod restarted once. It
also could not be adopted directly — Helm's merge patch cannot remove a live
`env.value` on an object it does not yet own, so the manifest had to be
`kubectl apply`'d by hand first. See the adoption log in `../FLEET-WIRING.md`.
Resolved; the credential did not change.

`correctDrift` is off in every file. Turn it on only after everything is adopted
and verified — it makes Fleet revert out-of-band `kubectl edit`s, which is the
goal eventually but will fight this cluster's hand-tuning habits.

## Status

| GitRepo | State |
|---|---|
| `lab-node-red` | ✅ adopted 2026-07-29 — no-op, no restart |
| `lab-emby` | ✅ adopted 2026-07-29 — no-op, no restart |
| `lab-resilio` | ✅ adopted 2026-07-29 — no-op, no restart |
| `lab-hermes` | ✅ adopted 2026-07-29 — needed a manual pre-apply; one expected restart |
| `lab-ai` | 🔶 **partial** — 5 raw paths adopted 2026-07-29 (all no-ops). The 3 Helm paths (`04-ollama`, `05-open-webui`, `06-milvus`) and `21-unsloth-studio` (fresh install, not an adoption) are **not yet added to the live GitRepo**. No `.yaml` file — patch `spec.paths` to widen |
| `lab-metallb-system` | not yet applied |
| `lab-nvidia-device-plugin` | not yet applied |
| `lab-cattle-monitoring-system` | not yet applied |
| `lab-longhorn-system` | not yet applied |

`c-nnzn9` (sdf1) is the only Fleet-managed downstream; the junk
`cluster-ee8f7993b3a6` was deleted 2026-07-29. So the `ash4d-lab: ""` selector in
these files resolves to exactly one cluster.

## Prerequisite: the fleet-agent must be able to register

This blocked everything until 2026-07-29 (`agent-tls-mode` was `strict` with an
empty `apiServerCA`); see `../FLEET-WIRING.md`. If bundles ever sit in
`WaitApplied` with an empty BundleDeployment status again, check this first —
note the resource must be fully qualified, or `cluster` resolves to
`clusters.cluster.x-k8s.io` and returns a confusing NotFound:

    kubectl --context rancher -n fleet-default get clusters.fleet.cattle.io c-nnzn9 \
      -o jsonpath='{.status.agent.lastSeen}'

An empty or `null` result means the agent has never checked in, and bundles will
sit in `WaitApplied` forever.
