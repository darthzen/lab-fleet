# Fleet GitRepos — one per namespace

These are Fleet **`GitRepo` custom resources** (`gitrepos.fleet.cattle.io`), not
git repositories. Each one points Fleet at the existing `lab-fleet` repo and
lists which paths to render. They live on the **Rancher controller**
(192.168.7.148, kubectl context `rancher`) — not on sdf1 — so they are not part
of any bundle in this repo. Kept here as the versioned source of record.

    kubectl --context rancher apply -f 14-cluster-mgmt/gitrepos/lab-node-red.yaml

## Convention: `lab-<namespace>`

One GitRepo per Kubernetes namespace, so each namespace's workloads can be
adopted, rolled back, or paused independently of every other.

| GitRepo | Namespace | Paths | Risk |
|---|---|---|---|
| `lab-node-red` | `node-red` | `12-node-red` | low — **start here** |
| `lab-emby` | `emby` | `11-emby` | low |
| `lab-resilio` | `resilio` | `13-resilio` | low |
| `lab-hermes` | `hermes` | `10-hermes` | low–med — needs `hermes-webui` Secret |
| `lab-ai` | `ai` | 8 paths (04→09) | med — add one at a time |
| `lab-metallb-system` | `metallb-system` | `01-networking`, `01-networking/pools` | med–high |
| `lab-nvidia-device-plugin` | `nvidia-device-plugin` | `03-gpu`, `03-gpu/runtimeclass` | med–high |
| `lab-cattle-monitoring-system` | `cattle-monitoring-system` | `03-gpu/dcgm-exporter` | med |
| `lab-longhorn-system` | `longhorn-system` | `02-longhorn` | **highest — adopt last** |

Adopt in that order. Within `lab-ai`, add paths one at a time — raw manifests
(`08-indexer`, `09-mcp`, `07-comfyui`, `06-milvus/attu`,
`04-ollama/ollama-exporter`) before the Helm charts (`04-ollama`,
`05-open-webui`, `06-milvus`).

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

The one exception is `lab-hermes`: `HERMES_WEBUI_PASSWORD` moves from an inline
value to a `secretKeyRef`, which *is* a pod template change, so that pod restarts
once. Seed the Secret with the value already in the live spec and the credential
itself does not change.

`correctDrift` is off in every file. Turn it on only after everything is adopted
and verified — it makes Fleet revert out-of-band `kubectl edit`s, which is the
goal eventually but will fight this cluster's hand-tuning habits.

## Status

| GitRepo | State |
|---|---|
| `lab-node-red` | ✅ **adopted 2026-07-29** — verified no-op, no pod restart |
| everything else | not yet applied |

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
