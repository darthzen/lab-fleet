# 04 — Ollama (otwld/ollama-helm)

    helm repo add ollama-helm https://helm.otwld.com/
    helm upgrade --install ollama ollama-helm/ollama --version 1.67.0 -n ai --create-namespace -f values.yaml

Key choices: Tesla V100 (32 GB) pinned by GPU UUID; flash attention with an
**f16 KV cache** (full precision — accuracy over concurrency);
`OLLAMA_CONTEXT_LENGTH=98304` (96k) with `OLLAMA_NUM_PARALLEL=1`;
LoadBalancer at `192.168.7.153:11434` so LAN clients (Claude Code via
ollama-code-mcp, the Xcode instance) reach it directly. 200Gi Longhorn PV for
models. Coding tags are declared in `values.yaml` under `ollama.models.create`
with sampling pinned for precision — see "Sampling tags" below.

## Context length

`OLLAMA_CONTEXT_LENGTH` is **per parallel slot**, not a pool divided among them.
Resolved 2026-07-30 against the live pod: 262144 with `NUM_PARALLEL=1` held
~30.4 GiB of the 31.75 GiB card, so two slots at that context would need ~43 GiB.

History:

- 2026-07-18 — set to 65536 because hermes-agent (`10-hermes`) needs at least
  64k. Below that, hermes auto-detected 262144 from model metadata, packed
  prompts to fit, and every response came back `finish_reason='length'`.
- 2026-07-29 — an out-of-band `kubectl edit` raised it to 262144. That pushed
  ~703 MiB of qwen3-coder:30b onto the CPU and prompt processing fell to
  152 tok/s, declining further as context grew.
- 2026-07-30 — settled at 98304 (96k) x 2 slots. Still clears the 64k floor.
- 2026-07-30 (later) — briefly 131072 (128k) x 1 slot with **f16 KV**, from a
  derived KV estimate. The first real load spilled 5 layers (~3.6 GiB) to CPU:
  the derivation had divided the measured KV delta by 2 slots, but a
  per-request `num_ctx` allocates that amount **total**, so the true cost is
  double what was computed. Corrected the same day by load-testing.
- 2026-07-30 (final) — **98304 (96k) x 1 slot, f16 KV.** Largest tested
  configuration that stays fully GPU-resident.

## VRAM budget

Primary model is `qwen3.6:27b` (27.8B dense, UD-Q6_K_XL, arch `qwen35` —
64 blocks, hybrid attention + state-space). KV cost **cannot be computed from
GGUF metadata**: `qwen35.attention.head_count_kv` is null and the ratio of
full-attention to state-space layers is not exposed. Ground truth comes from
the model-load log (`llama_kv_cache` lines, 2026-07-30): 131072 ctx at f16
allocates **8192 MiB = 64 KiB/token exactly**. The hybrid-SSM discount is real
(~1/3 the cost of a comparable full-attention stack) but half as large as the
first derivation claimed — see the values.yaml comment for the failure mode.

Load tests at f16 x 1 slot (`size == size_vram` means fully GPU-resident):

| `num_ctx` | Result |
|---|---|
| 98304 (96k) | **29.21 GiB, fully on GPU — current setting** |
| 106496 (104k) | spills ~2 GiB to CPU |
| 114688 (112k) | spills ~2.1 GiB |
| 131072 (128k) | spills ~3.6 GiB, 5 layers offloaded |

KV scales as `ctx x slots x 64 KiB` at f16 (q8_0 would be ~34.8 KiB/token —
not used; accuracy priority).

After any change to context, parallelism, or KV cache type, confirm the model is
entirely on GPU:

    curl -s http://192.168.7.153:11434/api/ps | jq '.models[] | {size, size_vram, context_length}'

`size_vram` must equal `size`. Any gap is CPU offload — reduce context or slots.
Do not fall back to q8_0 KV to close a gap without an explicit decision; dropping
KV precision is what the 2026-07-30 change exists to avoid.

Flash attention on Volta (SM70) is **confirmed working** — the 2026-07-30 load
log reads `llama_context: flash_attn = enabled` and `warmup: flash attention is
enabled`. The former open question is closed.

## Sampling tags

The coding tags (`*-precise`) are declared in `values.yaml` under
`ollama.models.create` — Fleet is the source of truth for sampling parameters,
and the tags are recreated automatically on a volume rebuild. Do not create or
tune tags ad hoc on the server; change `values.yaml` and let Fleet sync.

Superseded tags that predate this (created on the server 2026-07-30, params
recorded here before retirement — both parents were the Q4_K_M pulls and both
carried the same precise sampling as the declared tags):

- `qwen3.6:27b-precise` — FROM `qwen3.6:27b` (Q4_K_M, tag since deleted)
- `qwen3-coder:30b-precise` — FROM `qwen3-coder:30b` (Q4_K_M, tag since
  deleted), plus stops `<|im_start|>` `<|im_end|>` `<|endoftext|>`

## Upgrade procedure

**Fleet is canonical (Rick, 2026-07-30). Every change to this deployment goes
through git — edit `values.yaml`, commit, push, and let Fleet sync. No manual
`helm upgrade`, no `kubectl edit`.**

Rollout still requires the scale-to-zero guard: on 2026-07-16 an in-place
change wedged the old ollama process, which ignored SIGTERM and took the V100
off the bus ("GPU is lost", `nvidia-smi` hung on sdf1). Force-deleting the
stuck pod then produced a ~250-pod `UnexpectedAdmissionError` ReplicaSet storm.

Sequence for a config change:

    # 1. Drain the running pod BEFORE the push
    kubectl --context sdf1 -n ai scale deploy/ollama --replicas=0
    kubectl --context sdf1 -n ai rollout status deploy/ollama --timeout=180s
    # 2. Push the commit; Fleet applies the bundle and restores replicas
    git push

Kube contexts on the Mac are `rancher` (khyron, the default) and `sdf1` —
commands without `--context sdf1` land on the wrong cluster. (Older notes said
`default`; that context name is gone.)

## ollama-exporter

`ollama-exporter/` is a **separate Fleet bundle** (Fleet allows one chart per
path, and this dir is a Helm bundle — same split as `06-milvus/attu`). Its own
`fleet.yaml` splits it out of the parent scan automatically — it is discovered
via the `04-ollama` path entry, with **no explicit child path** in the `lab-ai`
GitRepo. Do not add one: a `.fleetignore` does NOT suppress nested-bundle
discovery, so listing both the parent and the child makes the gitjob write
this bundle twice in one pass and fail on its own conflict (2026-07-30,
three identical failures). It does two things:

- **9400** — Prometheus metrics, polling Ollama every 15s for loaded-model and
  VRAM state.
- **9401** — a transparent reverse proxy to `ollama:11434`. Clients pointed here
  instead of at Ollama directly get their requests counted. The docs-rag MCP
  server (`09-mcp/docs-rag/`) and all three doc indexers (`08-indexer/`) are
  wired through 9401 for exactly this reason.

The image lives in the in-cluster Harbor (`registry.ash4d.com`), so the
`harbor-pull` imagePullSecret must exist in the `ai` namespace or the bundle
sticks on `ImagePullBackOff`. That Secret is not in this repo.

## Fleet

`fleet.yaml` sets `takeOwnership: true` and Fleet watches this bundle. If Fleet
syncs from git before a manual `helm upgrade`, Fleet applies the change and the
manual command becomes a no-op. Decide which one is driving before running either.
