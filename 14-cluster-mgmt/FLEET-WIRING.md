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

Order: `lab-nemoclaw` → `lab-node-red` → `lab-emby` / `lab-resilio` →
`lab-ash4d-origin` → `lab-hermes` → `lab-ai` (nine paths, one at a time) →
`lab-openshell` → `lab-buzz` → `lab-lab-memory` → `lab-metallb-system` /
`lab-nvidia-device-plugin` / `lab-cattle-monitoring-system` →
`lab-cert-manager` → `lab-longhorn-system` last.

`lab-nemoclaw` moves to the front because it has no pod templates at all — only
Namespaces, RBAC, NetworkPolicies and a PVC — so it is the one adoption that
physically cannot restart anything. `lab-openshell` must follow it (its chart
writes into `nemoclaw-sandboxes`). `lab-cert-manager` sits second-to-last
despite being a platform component, because it owns the cert-manager CRDs.

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

  A diff here means the **recorded release** disagrees with live. That is worth
  knowing, but it is not the same as the *repo* disagreeing with live — and only
  the latter decides whether adoption changes anything. Pair this with the
  `helm template` render check in the `lab-ai` adoption-log entry; on open-webui
  the two checks give opposite answers, and the render is the one that was right.

- **A transient git-polling timeout parks a GitRepo for up to 2 hours, and the
  error it leaves behind is stale.** Symptom: `Stalled=True` on several GitRepos
  at once with

      Get "https://github.com/darthzen/lab-fleet/info/refs?service=git-upload-pack": context deadline exceeded

  while `Ready=True` and every BundleDeployment is still `ready/nonModified`.
  Nothing is wrong with the deployed state — this condition is about *polling for
  new commits*, not about applying them. **Check the BundleDeployments before
  reacting to it.**

  Observed 2026-07-30: four repos polled fine at 03:32:58Z, all four failed
  within 13s of each other at 03:36:3xZ, and then **no further poll happened for
  28+ minutes**. `lab-ai` looked healthy only because unrelated `spec.paths`
  patches kept forcing it to reconcile. The failure is not self-healing on a
  short timescale: recovery needs a new commit, a write to the object, or the
  `GITREPO_SYNC_PERIOD` resync — which Rancher sets to **`2h`** on the `gitjob`
  deployment in `cattle-fleet-system`. There is no webhook configured
  (`status.webhookCommit` is empty on every repo), so commit pickup depends
  entirely on polling. A blip therefore costs real sync latency, not just a red
  icon.

  **Mitigated 2026-07-30, partially.** Every GitRepo file now sets
  `pollingInterval: 60s` explicitly, which bounds staleness and puts the value
  under review in git instead of relying on a controller-wide default.

  The remaining knob is `gitjob.syncPeriod`, and it is **deliberately left at
  `2h`** because it is not ours to change safely. It is a value of the
  Rancher-managed `fleet` Helm release (`fleet-109.0.4+up0.15.4` in
  `cattle-fleet-system` on the controller, revision 4 as of 2026-07-30 — Rancher
  reconciles it, so it does get rewritten). Hand-patching the `gitjob`
  Deployment's env would be reverted; a manual `helm upgrade` of that release
  would touch the whole Fleet control plane and could be undone by Rancher's own
  reconcile, taking the setting with it. The supported change is:

      helm --kube-context rancher -n cattle-fleet-system upgrade fleet \
        <rancher's fleet chart> --reuse-values --set gitjob.syncPeriod=15m

  Do that only deliberately, and re-check it after any Rancher upgrade. The
  properly architectural fix is a GitHub webhook so commits are push-triggered
  and polling latency stops mattering — but the controller is on a LAN address
  (192.168.7.148) and would need public ingress for GitHub to reach it, which is
  a bigger change than this problem justifies.

  Clear a stuck one with any metadata write — no generation bump, no job, no
  redeploy:

  ```bash
  kubectl --context rancher -n fleet-default annotate gitrepo <name> \
    probe.local/nudge="$(date -u +%s)" --overwrite
  # ~20s later, confirm Stalled=False, then drop the annotation:
  kubectl --context rancher -n fleet-default annotate gitrepo <name> probe.local/nudge-
  ```

  Verified harmless on all five repos: generations unchanged, no Jobs created in
  `fleet-default`, no pod restarts or startTime changes downstream. Do **not**
  reach for `fleet.cattle.io/force-update` — that forces an actual redeploy.

- **🔴 "Roll back by removing the path" DESTROYS an adopted Helm release.
  Learned the hard way on 2026-07-30 — it deleted karakeep.** Removing a path
  from `spec.paths` deletes that bundle, and deleting a bundle whose Helm release
  Fleet has taken ownership of **uninstalls the release**. That is fine for a
  bundle still stuck in `WaitApplied` that never got ownership, and fine for raw
  bundles Fleet created itself. It is NOT fine once `takeOwnership` has
  succeeded: Fleet becomes the release owner, and removing the path runs the
  equivalent of `helm uninstall`.

  What it cost: karakeep's StatefulSets, its chrome Deployment, its Service and
  Ingress, and the `karakeep-meilesearch` PVC were all deleted. Recovery was a
  plain `helm upgrade --install` with this repo's own values.

  What survived, and why it matters:
  - `data-karakeep-0` — a StatefulSet `volumeClaimTemplates` PVC. Kubernetes
    does not garbage-collect these when the StatefulSet goes, so the primary
    data volume was still `Bound` and the reinstalled StatefulSet re-bound the
    same Longhorn volume by name.
  - `karakeep` and `karakeep-meilesearch` Secrets — untouched **only because**
    `18-lab-memory/values.yaml` had disabled the chart's Secret objects. Had
    they been chart-managed, the uninstall would have deleted both credentials.
  - The `karakeep-meilesearch` PVC did NOT survive: a plain subchart PVC is
    Helm-owned, so it was deleted. Meilisearch is a rebuildable index, so this
    cost a reindex rather than data.

  **Safe rollback for a bundle that reached ownership:** do not touch
  `spec.paths`. Either leave it and fix forward, or `spec.paused: true` to stop
  Fleet acting while you work. If the path must go, `helm uninstall` is what you
  are actually authorising — take a backup first.

- **`kubectl diff` clean does NOT mean Fleet will apply cleanly.** This is the
  pre-flight gap that caused the incident above. Fleet applies server-side, so
  it needs *field ownership*, not just matching values. karakeep failed with:

      Apply failed with 6 conflicts: conflicts with "helm":
      - .spec.template.spec.hostIPC
      - .spec.volumeClaimTemplates
      - .spec.template.spec.containers[name="karakeep"].resources.limits.cpu

  The values were semantically identical — live had `cpu: 1` where the chart
  renders `1000m`, and live simply omitted `hostIPC/hostNetwork/hostPID` where
  the chart renders explicit `false`. `kubectl diff` normalises all of that and
  reports clean. Server-side apply does not: it sees another manager (`helm`,
  from the original client-side-apply install) owning those paths and refuses.

  Neither escape is free. `helm.force: true` replaces objects, and
  `.spec.volumeClaimTemplates` is immutable, so on a StatefulSet that risks a
  delete/recreate of the data volume. Stripping the stale `helm` entry from
  `managedFields` lets Fleet take over but then it *writes* its normalised
  values, rolling the pod.

  So: add an ownership pre-flight before adopting any Helm release that predates
  Fleet. `kubectl apply --server-side --dry-run=server` against the render will
  surface the conflicts that `kubectl diff` hides.

  **The working procedure, proven on cert-manager 2026-07-30.** Hand the fields
  to Fleet's own field manager, `fleetagent`, *before* applying the GitRepo:

      helm template <rel> <chart> --version <v> -n <ns> -f values.yaml \
        --no-hooks > /tmp/r.yaml

      # 1. see the conflicts
      kubectl -n <ns> apply --server-side --field-manager=fleetagent \
        --dry-run=server -f /tmp/r.yaml

      # 2. confirm the API server would ACCEPT the forced apply
      kubectl -n <ns> apply --server-side --force-conflicts \
        --field-manager=fleetagent --dry-run=server -f /tmp/r.yaml

      # 3. confirm what would actually CHANGE, as opposed to merely change owner
      kubectl diff -f /tmp/r.yaml

      # 4. only if step 3 shows nothing you did not intend, drop --dry-run
      kubectl -n <ns> apply --server-side --force-conflicts \
        --field-manager=fleetagent -f /tmp/r.yaml

  Step 3 is what makes this safe: on cert-manager, 5 of 48 objects conflicted
  (the two webhook configurations' `.rules`, three Deployments'
  `POD_NAMESPACE.valueFrom.fieldRef`, and the controller's `.args`) but the diff
  showed only ONE real change — the intended `extraArgs`. Everything else was
  ownership with byte-identical values, and applied without touching the object:
  the cainjector and webhook pods kept their original UIDs, and only the
  controller rolled. All 9 Certificates stayed Ready throughout.

  `fleetagent` (no hyphen) is the manager name, confirmed from `managedFields`
  on an already-adopted object. Note that `helm` and `fleetagent` can co-own an
  object happily once values agree — that is why buzz and openshell adopted with
  no conflict at all: their renders matched live exactly.

- **A nested path with its own `fleet.yaml` deploys as soon as its PARENT path
  is adopted — it is not a staging gate.** Fleet scans the parent path
  recursively; a nested `fleet.yaml` splits that subdirectory into its own
  *bundle*, but it is still rendered and applied under the parent's path entry.
  Observed three times on 2026-07-30: adopting `09-mcp` immediately deployed
  `09-mcp/ollama-code`, `17-buzz` brought `17-buzz/minio`, and `18-lab-memory`
  brought `18-lab-memory/raw` — none of which were in `spec.paths`.

  Consequence: the "apply the first path, then patch in the second" staging
  pattern **does not work for nested paths**. It only works for siblings, the way
  `01-networking` and `01-networking/pools` are siblings. If a second path must
  be genuinely gated, make it a sibling directory, not a child.

- **A field the API server silently discards makes a bundle permanently
  `Modified`.** The buzz redis subchart sets
  `updateStrategy.rollingUpdate.maxUnavailable: 1`, but this cluster has
  `MaxUnavailableStatefulSet` disabled (`kubernetes_feature_enabled{...} 0`), so
  the API server strips it on every apply. Fleet re-renders it, never sees it
  land, and reports `Modified` forever with no path to convergence — which hides
  real drift behind permanent noise. Fixed by nulling the value in
  `17-buzz/values.yaml`. Confirm suspicions with
  `kubectl patch --dry-run=server` and check whether the field comes back.

- **cert-manager's DNS-01 flags exist only on the live object — omitting them
  is a delayed, cluster-wide certificate outage.** The live `cert-manager`
  Deployment carries two args the chart does not render:

      --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53
      --dns01-recursive-nameservers-only

  Without them cert-manager runs its DNS-01 self-check against the cluster's own
  resolver, which does not serve the public view of `ash4d.com`. It would never
  observe the `_acme-challenge` TXT record it had just written, so every
  Challenge would sit pending until it timed out. **Nothing breaks at adoption
  time** — existing certs serve until renewal — which is what makes this
  dangerous: it surfaces weeks later as certs expiring on every ash4d.com
  hostname at once. Now captured as `extraArgs` in `15-cert-manager/values.yaml`.
  Same class as Longhorn's replica count: a value that exists only on the live
  object, invisible until much later.

- **A mutable chart tag is not a pin — `helm template` it before trusting it.**
  OpenShell is published only as `0.0.0-dev`, and that tag had *already* drifted
  from the running release: pulling it on 2026-07-30 yielded an added
  `server.workspaceStorageClass` value, added supervisor sidecar-topology
  options, and a rewritten `_helpers.tpl`. Writing `version: "0.0.0-dev"` the
  way `04-ollama` writes `version: "1.67.0"` looks identical but is not — it
  would have silently *upgraded* openshell under the guise of adopting it. When
  upstream offers no immutable version, vendor the chart. See
  `20-openshell/fleet.yaml`.

- **🔴 Before concluding a chart is unpublished, pull the EXACT ref from the
  install command. `buzz` was wrongly declared lost.** The first check probed
  `oci://ghcr.io/block/buzz`, got a 404, and the chart was vendored on that
  basis. The real ref is `oci://ghcr.io/block/buzz/charts/buzz` — note the
  `/charts/` segment — and `0.1.6` pulls fine. It was written down in two places
  the whole time: the header comment of `17-buzz/values.yaml`, and shell history.
  41 files were vendored that did not need to be. Now referenced upstream, which
  is both the repo convention and an immutable semver pin. Verified: the
  published chart renders byte-identical to the recovered copy, and to live.

  A misleading `home:`/`sources:` URL is not evidence either — this chart points
  at `github.com/block/buzz`, an unrelated audio-transcription desktop app.

- **`openshell` DOES have immutable tags; it still has to be vendored, for a
  narrower reason.** The earlier claim that "there is no immutable version to
  pin" was wrong: `ghcr.io/nvidia/openshell/helm-chart` publishes `0.0.37`
  through `0.0.42` plus content-addressed `0.0.0-dev.<sha>` tags. But the running
  release was installed from the floating `0.0.0-dev` tag, and **none of the
  published semvers reproduces it** — each renders 8 objects against live's 10.
  So the vendored chart stays, because it is the only artifact known to match
  live. To un-vendor it, find the `0.0.0-dev.<sha>` tag whose render matches
  (~90 candidates, listable from the ghcr tags API) and pin that.

- **A lost chart is recoverable from the cluster running it.** Helm stores the
  chart verbatim inside the release Secret, which is how openshell's chart was
  reconstructed from `sh.helm.release.v1.<rel>.v<n>`. Two traps when doing
  this:
  - Helm rewrites a dependency's `name` to its **alias** when storing a chart,
    so the recovered `Chart.yaml` disagreed with the recovered `Chart.lock`
    (`postgresql` vs `postgres`) and no `helm dependency build` was possible
    until it was set back.
  - Subcharts are **not** in the release Secret. Re-fetch them pinned to the
    exact versions the recovered `Chart.lock` records, not the `0.19.x`-style
    ranges the chart declares, or the render drifts. Commit the resulting
    `charts/*.tgz` — Fleet does not run `helm dependency build`.

- **Jobs do not belong in a Fleet bundle.** A `Job` spec is near-immutable, so a
  Job inside a synced path makes Fleet fight the API server on every subsequent
  change, and a Job that has already completed and been reaped reads as a
  *creation* rather than a no-op. Three were split out and renamed `.yaml.txt`
  so Fleet never applies them, following the
  `09-mcp/github-mcp-token.secret.example.yaml.txt` convention:
  `17-buzz/minio/buzz-minio-mkbucket.job.yaml.txt` and
  `18-lab-memory/raw/eval-job.yaml.txt`.

- **Fleet applies `*.json` too.** `nemoclaw-ops-agent/deploy/audit/` ships an
  `audit-record.schema.json` next to its manifests; vendoring the directory
  wholesale would break the bundle with `Object 'Kind' is missing`. This is the
  same failure the `fleet.yaml` gotcha produces under `kubectl diff`, but here it
  breaks the real sync, not just a pre-flight. Vendor manifests, not directories.

- **`03-gpu/runtimeclass` is contested — k3s owns those objects.** The live
  `nvidia` / `nvidia-experimental` RuntimeClasses carry
  `objectset.rio.cattle.io/owner-gvk: k3s.cattle.io/v1, Kind=Addon` and
  `owner-name: runtimes`: they come from k3s's bundled `runtimes` Addon, not from
  this repo. Adopting the path aims Fleet and k3s's addon controller at the same
  cluster-scoped objects, and losing that tug-of-war breaks GPU scheduling for
  ollama, comfyui and dcgm-exporter at once. The path has been **removed from
  `gitrepos/lab-nvidia-device-plugin.yaml` pending a decision** — leaving these to
  k3s, like Traefik, is a legitimate outcome. Found 2026-07-29; not yet resolved.
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
  | `cloudflare-api-token` | `cert-manager` | `letsencrypt-dns` DNS-01 solver | ✅ |
  | `buzz-relay` | `buzz` | relay **and** both bundled subcharts | ✅ |
  | `karakeep` | `lab-memory` | `NEXTAUTH_SECRET` | ✅ |
  | `karakeep-meilesearch` | `lab-memory` | `MEILI_MASTER_KEY` (chart's spelling) | ✅ |

  The last two are prerequisites *because* `18-lab-memory/values.yaml` sets
  `secrets.karakeep.enabled: false` and `secrets.meilesearch.enabled: false`.
  Left enabled, the chart's `default (randAlphaNum 48)` would mint new values on
  every render and the first Fleet sync would rotate both credentials —
  invalidating every session and locking Meilisearch out of its own index. The
  same reasoning as `hermes-webui`: a value that cannot live in a public repo
  becomes an out-of-band prerequisite, not a committed value.

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

`2026-07-30` — **ADOPTION RESULTS. 5 of 7 new GitRepos adopted; karakeep failed
and was destroyed and restored; cert-manager deliberately held.**

Live state after this session — every BundleDeployment `ready=true`:

| GitRepo | Paths live | Result |
|---|---|---|
| `lab-nemoclaw` | `19-nemoclaw` | ✅ `nonModified=true` first sync. Zero restarts, as predicted |
| `lab-ash4d-origin` | `16-ash4d-origin` | ✅ pod UID + startTime unchanged — true no-op |
| `lab-openshell` | `20-openshell` | ✅ pod unchanged; adopted existing release (rev 3 → 4) |
| `lab-buzz` | `17-buzz` + nested `/minio` | ✅ all 4 pods unchanged; release 7 → 11. Reported `Modified` until the redis `maxUnavailable` fix |
| `lab-lab-memory` | `18-lab-memory` + nested `/raw` | ✅ adopted on the second attempt via the SSA handoff — zero pod restarts, see below |
| `lab-ai` | + `09-mcp/ollama-code` | ✅ migration done, `ollama-code` namespace deleted |
| `lab-cert-manager` | `15-cert-manager` + nested `/issuer` | ✅ adopted after an SSA ownership handoff; controller rolled once, all 9 Certificates stayed Ready |

**The karakeep incident, in order.** Adopting `18-lab-memory` failed on
server-side-apply field-manager conflicts (see Watch-outs) — `kubectl diff` had
been clean, which is exactly the gap. Fleet retry-looped the release from rev 2
to rev 18, all `failed`, while the workload stayed healthy and untouched. To stop
the loop, `spec.paths` was narrowed to `18-lab-memory/raw`. **That uninstalled
the release**, deleting karakeep's two StatefulSets, its chrome Deployment,
Service, Ingress, and the `karakeep-meilesearch` PVC.

Restored with `helm upgrade --install karakeep karakeep-app/karakeep --version
0.32.0 -n lab-memory -f 18-lab-memory/values.yaml`. Outcome:

- **Primary data intact.** `data-karakeep-0` is a `volumeClaimTemplates` PVC,
  which Kubernetes does not garbage-collect, so it stayed `Bound` and the new
  StatefulSet re-bound the same Longhorn volume
  (`pvc-0acd3510-43ff-438c-8a54-c9fa8f310298`, 18d old).
- **Credentials intact** — and only because this repo had already disabled the
  chart's Secret objects. Chart-managed Secrets would have been deleted.
- **Meilisearch index lost.** Its PVC was a plain Helm-owned PVC. A fresh 1Gi
  volume was created; karakeep needs a reindex to restore search. Bookmarks
  themselves are in the primary volume and were never at risk.
- Verified after restore: 3/3 pods Running, `/api/health` 200,
  `karakeep-ash4d-tls` still valid to 2026-10-09.

karakeep is now running **unmanaged again**, exactly as before this session.
Re-adopting it requires resolving the field-ownership conflict first — see the
`kubectl diff` watch-out for why neither `helm.force` nor `managedFields` surgery
is free on a StatefulSet with an immutable `volumeClaimTemplates`.

**cert-manager was adopted later the same day**, once the SSA pre-flight
procedure existed. It hit 5 conflicts across 48 objects, but the value-level diff
proved only the intended `extraArgs` change was real, so the ownership handoff
was safe. Result: the controller pod rolled once, the cainjector and webhook pods
kept their original UIDs, the DNS-01 args survived Fleet taking over, and all 9
Certificates plus the ClusterIssuer and 6 CRDs came through untouched. Full
procedure in the `kubectl diff` watch-out.

**karakeep was then adopted too, cleanly.** Two things made the second attempt a
true no-op where the first destroyed it:

1. The accidental reinstall had applied the chart's own render, so live *was* the
   render. `kubectl diff` (step 3 of the procedure) came back completely empty —
   the 14 conflicts were pure ownership with zero value differences. The
   cosmetic mismatches that caused the original failure (hand-added `OCR_USE_LLM`
   ordering, `cpu: 1` vs `1000m`) had been normalised away.
2. `deploy/secrets.env` had been restored first, so the credentials were no
   longer single-copy.

Result: all 10 objects handed to `fleetagent`, **every pod UID unchanged**, both
PVCs still bound to their original volumes, both Secrets still at their original
`resourceVersion` (never rotated at any point today), `/api/health` 200, and the
search index intact at 120 documents.

**Mid-way mistake worth recording:** re-applying every GitRepo file to add
`pollingInterval` silently reset `lab-lab-memory`'s `spec.paths` from the
narrowed `18-lab-memory/raw` back to the file's `18-lab-memory`, restarting the
failing karakeep retry loop (release reached revision 8, all failed). Nothing
broke, because this time the loop was stopped with `spec.paused: true` rather
than by removing the path. **A GitRepo file is the source of truth for
`spec.paths`** — if the live value has been narrowed by hand, re-applying the
file undoes that. Narrow the file too, or expect the reset.

Everything below this line was written before adoption and describes the
pre-flight, which remains accurate.

| Path | Source project | Pre-flight result |
|---|---|---|
| `15-cert-manager` | (live state) | clean **after** adding the two DNS-01 `extraArgs`; restarts controller once (arg order) |
| `15-cert-manager/issuer` | ollama-code-mcp repo | `kubectl diff` clean |
| `16-ash4d-origin` | (live state) | `kubectl diff` clean — true no-op |
| `17-buzz` | buzz-relay repo + release Secret | renders **byte-identical** to live |
| `17-buzz/minio` | buzz-relay `minio.yaml` | clean once the bootstrap Job is split out |
| `18-lab-memory` | lab-memory repo | clean **after** fixing 2 drifts; rolls karakeep once |
| `18-lab-memory/raw` | lab-memory repo | `kubectl diff` clean |
| `19-nemoclaw` | nemoclaw-ops-agent repo | `kubectl diff` clean — no pod templates at all |
| `20-openshell` | release Secret | renders identically to live, all 3 groups |
| `09-mcp/ollama-code` | ollama-code-mcp repo | clean in place; **migration**, see runbook |

Four repo-vs-live drifts were found and resolved in the repo's favour of *live*,
because adoption must not change a running cluster:

1. **cert-manager** — two DNS-01 args on the live Deployment, in no chart value.
   Would have been a delayed cluster-wide cert outage. See Watch-outs.
2. **karakeep `OLLAMA_BASE_URL`** — recorded release said
   `http://192.168.7.153:11434`, live object said
   `ollama-exporter.ai.svc.cluster.local:9401`. Identical shape to the
   open-webui drift; live wins.
3. **karakeep secrets** — the chart regenerates `NEXTAUTH_SECRET` and
   `MEILI_MASTER_KEY` unless pinned, and the live values came from a git-ignored
   file. Chart-managed Secrets disabled instead; both are now prerequisites.
4. **openshell `sandboxNamespace`** — the nemoclaw repo's values say `nemoclaw`,
   live says `nemoclaw-sandboxes`. The repo copy is stale and would have moved
   the sandbox namespace out from under its own NetworkPolicy and RBAC.

Deliberately **excluded** from the repo, with reasons:

- **`registry` (Harbor).** Its objects carry `app.kubernetes.io/managed-by=Helm`
  but there is **no release Secret and no `meta.helm.sh/release-name`
  annotation** — Helm-labelled and ownerless, so the chart cannot be recovered
  the way buzz and openshell were, and no values source survives. It is also
  load-bearing: it serves the `ollama-exporter` image that the already-adopted
  `04-ollama/ollama-exporter` path pulls. Needs its own session.
- **`agent-sandbox-system`** — upstream
  `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0`, third-party,
  no source in `~/Developer`, no ownership markers.
- **`managed-agent`** — a single `registry.suse.com/bci/python:3.12` worker with
  no ownership markers and no identifiable source. Looks like a scratch
  experiment; identify it before adopting.
- **`trading-agent`** — 0 workloads, not deployable, not under active
  development. Excluded at the user's direction.
- **`ollama-exporter`** — already Fleet-managed as `04-ollama/ollama-exporter`.
  The `~/Developer/ollama-exporter` directory is the Go source for the image (its
  own OSS project, with goreleaser/CHANGELOG/LICENSE) and does not belong here.
- **`ash4d.com` the project** — this repo is already ash4d.com's `lab/`
  submodule, so vendoring it back would be circular. Only its manifests could
  come in, and its `deploy/` directory turned out to target the **GCP** cluster
  (namespace `ash4d`, absent here; `ingressClassName: nginx` on a Traefik
  cluster), so `16-ash4d-origin` was reconstructed from live instead.

Guiding rule confirmed by all of the above: **lab-fleet holds cluster state, not
application source.** Projects with their own repo keep it; only their manifests
land here. Source is vendored only when it is orphaned (`08-indexer`) or when a
chart exists nowhere else (`17-buzz`, `20-openshell`).

`2026-07-29` — **`lab-ai`: the five raw-manifest paths adopted. All no-ops.**
`08-indexer`, `09-mcp`, `07-comfyui`, `06-milvus/attu`,
`04-ollama/ollama-exporter` — added one at a time, each reaching
`ready=true, nonModified=true` on its first sync with no errors and no
`ErrApplied` retries. Each path became its own Helm release at revision 1
(`lab-ai-<path>`), so the `ai` namespace now holds five Fleet releases alongside
the three pre-existing chart releases.

**The three Helm paths (`04-ollama`, `05-open-webui`, `06-milvus`) are
deliberately NOT yet added** — pre-flight says they should be no-ops too (see
below), but they were left for a separate approved step.

Evidence, whole-namespace snapshot before vs after all five:

| Check | Result |
|---|---|
| Pod UIDs / startTimes / restart counts | **all identical** — nothing restarted |
| ReplicaSets (46 of them) | **identical**, no new ones, same replica counts |
| CronJob `generation` | **unchanged** (5 / 2 / 2) |
| Deployment `generation` | +1 on each of the 8 adopted — inert, as with node-red |
| StatefulSets (`open-webui`, `milvus-etcd`) | untouched — not in these bundles |
| `ollama-exporter` 9401 proxy | live-probed, returns `{"version":"0.32.0"}` |
| ComfyUI | still `replicas: 0`, not scaled up |
| `attu` Service | still `ClusterIP`, Ingress intact |

Note the generation bump lands on Deployments but **not** on CronJobs, which
narrows the earlier node-red observation: Helm rewrites the Deployment spec to
identical values, and CronJobs come out untouched entirely.

### Pre-flight that actually predicts Helm adoption — use this, not `helm get manifest`

The watch-out below says to diff `helm get manifest <release>` against live. That
catches out-of-band edits, but it does **not** answer the question that matters:
*what will Fleet apply?* Render the chart the way Fleet will — pinned version plus
the repo's own `values.yaml` — and diff **that** against live:

```bash
helm template <release> <repo>/<chart> --version <pinned> -n ai \
  -f <dir>/values.yaml --no-hooks > /tmp/render.yaml
kubectl diff -n ai -f /tmp/render.yaml
```

`open-webui` is exactly why this matters, and the two checks disagree on it:

- `helm get manifest open-webui` vs live → **shows a diff**: the recorded release
  still says `ollama:11434` for `OLLAMA_BASE_URLS` / `RAG_OLLAMA_BASE_URL`, while
  live was hand-edited to `ollama-exporter:9401`.
- `helm template` with `05-open-webui/values.yaml` vs live → **clean**, because
  the repo's values were already corrected to 9401.

So the alarming diff is *recorded-release* drift, not repo drift, and adoption
will close it rather than change the cluster. Reading only the first check would
have stalled this path for no reason. All three charts render clean against live:
`04-ollama` (release at revision 14), `05-open-webui`, `06-milvus`.

Two gotchas when running these diffs:

- **`kubectl diff -R -f <dir>` fails on the bundle's own `fleet.yaml`** —
  `Object 'Kind' is missing`. It is Fleet config, not a manifest. Exclude it:
  `find <dir> -name '*.yaml' -not -name 'fleet.yaml'`.
- **`helm template` emits `ollama-test-connection`**, a Pod annotated
  `helm.sh/hook: test`. It is absent from the cluster and will stay absent —
  test hooks run only on `helm test`, never on install/upgrade, so Fleet will not
  create it. Pass `--no-hooks` so it does not show up as a phantom addition.

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

**Next step:** `lab-ai`'s three Helm paths — `04-ollama`, then `05-open-webui`,
then `06-milvus`. Pre-flight is already done and all three render clean against
live (see the `lab-ai` entry above). Widen by patching `spec.paths` — there is
deliberately **no `gitrepos/lab-ai.yaml`** to apply, because a single file cannot
express a staged rollout without inviting a one-shot widen. The exact patch and
verify commands are in `gitrepos/README.md`.

### `09-mcp/ollama-code` — a migration, not an adoption (runbook)

Everything else in this repo is adopt-as-no-op. This path is the exception: it
moves the ollama-code MCP server out of its own `ollama-code` namespace into
`ai`. It **will** take `mcp-ollama.ash4d.com` down briefly. Downtime was
explicitly accepted (2026-07-30).

Why it cannot be done as a parallel run: Traefik would see two Ingresses both
claiming `mcp-ollama.ash4d.com` and the winner is undefined; and
`mcp-ollama-ash4d-tls` is namespace-scoped, so the Certificate does not follow
the Ingress — cert-manager's ingress-shim has to issue a fresh one in `ai` from
the `cert-manager.io/cluster-issuer` annotation, which is a full DNS-01 round
trip.

Pre-flight already done: the repo manifests are `kubectl diff`-clean against the
live objects in `ollama-code`, so placement is the only thing changing. None of
them hardcodes a namespace, so `defaultNamespace: ai` is what moves it.

    # 1. Remove the old Ingress FIRST so the host is never claimed twice.
    kubectl --context sdf1 -n ollama-code delete ingress ollama-code-mcp

    # 2. Add the path to lab-ai (see gitrepos/README.md for the full list).
    kubectl --context rancher -n fleet-default patch gitrepo lab-ai --type=merge \
      -p '{"spec":{"paths":["08-indexer","09-mcp","07-comfyui","06-milvus/attu","04-ollama/ollama-exporter","09-mcp/ollama-code"]}}'

    # 3. Confirm the new bundle is Ready, and that lab-ai-09-mcp did NOT change
    #    resource count (proving the nested fleet.yaml split it into its own bundle).
    kubectl --context rancher -n cluster-fleet-default-c-nnzn9-eaf6ebdbb298 \
      get bundledeployments -o custom-columns=\
    'NAME:.metadata.name,READY:.status.ready,NONMODIFIED:.status.nonModified' | grep lab-ai

    # 4. Wait for the new Certificate to go Ready in ai (DNS-01, allow a few minutes).
    kubectl --context sdf1 -n ai get certificate mcp-ollama-ash4d-tls -w

    # 5. Only once step 4 is Ready, retire the old namespace.
    kubectl --context sdf1 delete namespace ollama-code

**Rollback** (before step 5, which is the point of no return): remove
`09-mcp/ollama-code` from `spec.paths`, then re-apply the original manifests into
`ollama-code` from the `ollama-code-mcp` repo (`kubectl apply -n ollama-code -k
k8s/`). The old namespace still holds its own Certificate until step 5, so
rollback before then costs only another DNS-01 round trip.

Do not vendor `k8s/cert-manager-issuer.yaml` from that repo — it declares the
same cluster-scoped `letsencrypt-dns` ClusterIssuer that `15-cert-manager/issuer`
owns, and two bundles declaring one cluster-scoped object contend for it.

## Recovered original install commands (2026-07-30)

Found by searching the Ash4d Lab project at
`~/Dropbox/Claude Cowork/Job Search/_portfolio/`, which holds a
`lab-capture/lab-state-20260704-121209/` snapshot (a full `helm get values` dump
of every release as of 2026-07-04) plus the `lab-memory` planning docs.

**karakeep** — the exact installer is `deploy/install.sh` in the `lab-memory`
repo (not in Dropbox):

    helm repo add karakeep-app https://karakeep-app.github.io/helm-charts
    helm upgrade --install karakeep karakeep-app/karakeep -n lab-memory \
      -f deploy/values.yaml \
      --set applicationSecretKey="$NEXTAUTH_SECRET" \
      --set meilisearchMasterKey="$MEILI_MASTER_KEY" \
      --wait --timeout 10m

The two secrets were generated once by that script into `deploy/secrets.env`
(gitignored at `deploy/.gitignore:1`) and re-passed on every upgrade,
specifically because — in the script's own words — "the chart regenerates random
secrets on every upgrade if these are not pinned". That is the same trap
`18-lab-memory/values.yaml` avoids by disabling the chart's Secret objects.

> **`deploy/secrets.env` had been lost, and was recreated 2026-07-30** from the
> live Secrets, with both values verified to match by digest. Until then the
> karakeep and Meilisearch credentials existed *only* in the two cluster Secrets,
> which turned that day's accidental uninstall from "recovered fully" into a
> near-miss: had those Secrets been chart-managed they would have been deleted,
> and the credentials would have been **unrecoverable** — every session
> invalidated and Meilisearch permanently locked out of its index with no way to
> reproduce the key.
>
> The file is `chmod 600` and gitignored at `deploy/.gitignore:1`. Note
> `~/Developer` is a symlink into iCloud, so it does sync there — accepted
> deliberately, since the alternative was a single copy inside the cluster.
>
> **Two traps if you re-run `install.sh` now.** It reads the lab-memory repo's
> own `deploy/values.yaml`, not this repo's `18-lab-memory/values.yaml`, and the
> two have diverged:
>   1. That file still carries the stale
>      `OLLAMA_BASE_URL: http://192.168.7.153:11434`, so running it would revert
>      the live StatefulSet off the in-cluster `ollama-exporter:9401` proxy.
>   2. It leaves the chart's Secret objects enabled, so the two Secrets become
>      Helm-owned again — re-arming exactly the deletion path described above,
>      though now recoverable from `secrets.env`.

**cert-manager** — rev 1 on 2026-06-08, and the dump proves the supplied values
were only:

    helm install cert-manager jetstack/cert-manager --version v1.20.2 \
      -n cert-manager --set crds.enabled=true

This **independently confirms the DNS-01 watch-out above**: the 2026-07-04
snapshot records `extraArgs: []` in the effective values, and the live Deployment
that day carried just five args with no `--dns01-recursive-nameservers`. The two
DNS-01 flags therefore never came through Helm at any revision — they were added
by direct edit afterwards. `15-cert-manager/values.yaml` is the only place they
are written down.

**Harbor** — *not recorded anywhere.* The project references it only as a
consumer: `registry.ash4d.com`, robot accounts, and the `harbor-push` /
`harbor-pull` docker-registry Secrets in `ai`. The 2026-07-04 snapshot predates
the `registry` namespace (created ~07-12), so it captured nothing. This matches
the cluster: Helm-labelled objects, no release Secret, no
`meta.helm.sh/release-name`. Harbor's install remains unreconstructed, and
reconstructing it means deriving values from live objects.

### karakeep re-adoption is unblocked — the exact steps

The pre-flight from the Watch-outs, run for real (dry-run only, nothing changed):

    helm template karakeep karakeep-app/karakeep --version 0.32.0 -n lab-memory \
      -f 18-lab-memory/values.yaml --no-hooks > /tmp/kk.yaml
    kubectl -n lab-memory apply --server-side --field-manager=fleetagent \
      --dry-run=server -f /tmp/kk.yaml

reproduces all 14 conflicts against manager `helm` across `karakeep-chrome`,
`karakeep-meilisearch` and `karakeep`. Adding `--force-conflicts` to the same
dry-run **succeeds on all 10 objects**, including the StatefulSet — so the
API server does not reject it and `.spec.volumeClaimTemplates` is not actually
being changed (live and rendered are semantically identical; live only carries
server-defaulted `apiVersion`/`kind`/`volumeMode`).

Fleet's field manager is **`fleetagent`** (no hyphen), confirmed from
`managedFields` on the adopted buzz Deployment — where `helm` and `fleetagent`
coexist as Apply managers precisely because that render matched live exactly.

So the unblock is to hand those fields to `fleetagent` once, before adopting:

    kubectl -n lab-memory apply --server-side --field-manager=fleetagent \
      --force-conflicts -f /tmp/kk.yaml     # drop --dry-run to commit

Expect the karakeep and chrome pods to roll — the normalised values differ
cosmetically from live (`cpu: 1` → `1000m`, explicit `hostIPC: false`,
`initialDelaySeconds: 0`). Take a backup of the two Secrets first, and re-read
the path-removal warning in Watch-outs before adopting: with an owned release,
backing out means `helm uninstall`.

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
