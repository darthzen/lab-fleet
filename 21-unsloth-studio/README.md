# 21 — Unsloth Studio

Web GUI for LLM fine-tuning (LoRA/QLoRA and full fine-tuning) on the V100,
from the official `unsloth/unsloth` image — Studio UI on 8000 at
[unsloth.ash4d.com](https://unsloth.ash4d.com), Jupyter Lab on 8888 at
[jupyter.ash4d.com](https://jupyter.ash4d.com). SSH (port 22 in the image) is
deliberately not exposed.

## Install

The Secret must exist **before** the Fleet path is enabled or the pod sticks
in `CreateContainerConfigError`:

```bash
kubectl -n ai create secret generic unsloth-jupyter \
  --from-literal=JUPYTER_PASSWORD="$(openssl rand -base64 24)"
```

Hand-test without Fleet (optional):

```bash
kubectl apply -f unsloth-studio.yaml
```

Enable via Fleet by appending this path to the live `lab-ai` GitRepo — read the
current list first and append exactly one entry (see
`14-cluster-mgmt/gitrepos/README.md`):

```bash
kubectl --context rancher -n fleet-default get gitrepo lab-ai -o jsonpath='{.spec.paths}'
kubectl --context rancher -n fleet-default patch gitrepo lab-ai --type=merge \
  -p '{"spec":{"paths":[ <current live list...>, "21-unsloth-studio" ]}}'
```

Unlike the other `lab-ai` paths this is a **fresh install, not an adoption** —
Fleet deploys it as soon as the path lands, so the Secret and DNS
(`unsloth.ash4d.com`, `jupyter.ash4d.com` → Traefik) must already be in place.

## Image / version pinning

`unsloth/unsloth` publishes versioned tags; the pinned
`2026.5.9-pt2.10.0-vllm-0.16.0-cu12.8-studio-release-v0.1.43-beta-2026-MAY-31`
equals the `latest` digest verified 2026-07-30 (`sha256:f21629b9ae4e…`). Bump
the tag deliberately — it is a ~13 GB pull, so the first pod start on a new tag
is slow. Building a custom image (e.g. on SUSE BCI) was considered and
rejected: it would mean recreating the CUDA 12.8 / PyTorch 2.10 / Triton /
vLLM stack by hand for zero benefit.

The image is CUDA 12.8 — the host driver must satisfy CUDA 12.x compat
(`nvidia-smi` on sdf1 shows the driver's max supported CUDA version).

## GPU: replicas 0, V100 by UUID

Same pattern and same reason as ComfyUI (`07-comfyui/`): GPU access is
`runtimeClassName: nvidia` plus an explicit `NVIDIA_VISIBLE_DEVICES` UUID —
**not** a device-plugin `nvidia.com/gpu` request, which would let the plugin
override the pin and possibly hand out the 8 GB GTX 1070. The pinned UUID is
the Tesla V100 that Ollama holds with `OLLAMA_KEEP_ALIVE=-1`, so this
Deployment is **declared at `replicas: 0`**.

### Starting a fine-tuning session

1. Free the V100. Prefer the API unload over scaling ollama (Fleet will fight
   `kubectl scale` once `04-ollama` is Fleet-owned):

   ```bash
   curl http://192.168.7.153/api/generate -d '{"model":"<loaded-model>","keep_alive":0}'
   ```

   Confirm on the host that the V100 shows ~0 MiB used: `nvidia-smi`.
2. Edit `replicas: 1` in `unsloth-studio.yaml`, commit, push; Fleet's 60s poll
   picks it up. (Before Fleet owns this path, `kubectl -n ai scale deploy
   unsloth-studio --replicas=1` works too.)
3. When done, reverse: set `replicas: 0`, then load the ollama model again
   (any request to ollama reloads it).

### V100 constraints

SM 7.0 (Volta): **fp16 only — no bf16, no flash-attention-2.** Pick fp16 in
Studio's training options; bf16 runs will fail or silently fall back. 4-bit
QLoRA and fp16 LoRA both work; FP8 does not.

## Storage

One 70Gi Longhorn PVC (`unsloth-data`), single mount at `/workspace/work`
(the image's working-directory convention). `HF_HOME` is redirected to
`/workspace/work/.hf-home` so the base-model cache, datasets, and checkpoints
all live on the one PVC and survive pod restarts — the ComfyUI lesson ("both
mounts must be PVC-backed or installs die with the pod") solved with a single
mount.

70Gi fits a 13B-class fp16 base model plus datasets and LoRA checkpoints.
Expand online (Longhorn supports it) rather than over-claiming. Do not run
full-model checkpoint-heavy fine-tunes against this pool.

### Reduced from 100Gi on 2026-07-30

The original 100Gi was sized against "~412Gi of ~500Gi allocated". That is not
the limit that binds. Longhorn schedules replicas against
`(storageMaximum - storageReserved) x over-provisioning%`, which on sdf1 was
~764Gi with ~759Gi already scheduled — so this claim **bound but never got a
replica scheduled**. It sat at `actualSize 0` for hours, looking healthy in
`kubectl get pvc`, and the instant `22-openchoreo` freed 128Gi of budget it
took 100Gi of it and starved OpenChoreo's Prometheus of the 6Gi it needed.

Two things worth carrying forward:

- **`Bound` does not mean scheduled.** Check
  `kubectl -n longhorn-system get volumes.longhorn.io <pv>` for
  `robustness: healthy` before believing a claim is real. A `faulted` or
  unscheduled volume is a claim on future budget, not just a dormant one.
- **Shrinking is delete-and-recreate.** Kubernetes only permits PVC
  *expansion*, so this reduction required deleting the (empty) PVC and
  letting Fleet recreate it. That is only safe because the claim held no data
  and `unsloth-studio` sits at `replicas: 0`. Once real checkpoints live here,
  the same change costs a backup and restore.

## Resources

Requests `2 CPU / 8Gi`, limits `6 CPU / 28Gi`. The node is a single 16-thread
3700X with 64 GB running everything including the k3s control plane: the low
request keeps a `replicas: 0→1` flip schedulable with ollama, milvus, emby et
al. resident; the limits cap a runaway tokenization/dataset-prep burst before
it starves the node. No GPU resource entries (see above).

## Security

Jupyter is arbitrary code execution in a GPU pod behind a single password —
the `unsloth-jupyter` Secret. Never leave the image default (`unsloth`); the
create command above generates a random one. Retrieve it with:

```bash
kubectl -n ai get secret unsloth-jupyter -o jsonpath='{.data.JUPYTER_PASSWORD}' | base64 -d
```

TLS on both hosts via cert-manager (`letsencrypt-dns` DNS-01), certs issue
even while the Deployment sits at 0 (Traefik 502s until scale-up — expected).
