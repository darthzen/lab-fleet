# 04 — Ollama (otwld/ollama-helm)

    helm repo add ollama-helm https://helm.otwld.com/
    helm upgrade --install ollama ollama-helm/ollama --version 1.67.0 -n ai --create-namespace -f values.yaml

Key choices: Tesla V100 (32 GB) pinned by GPU UUID; flash attention with an
**f16 KV cache** (full precision — accuracy over concurrency);
`OLLAMA_CONTEXT_LENGTH=131072` (128k) with `OLLAMA_NUM_PARALLEL=1`;
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
- 2026-07-30 (later) — moved to 131072 (128k) x 1 slot with **f16 KV**, sized
  by measurement for the new primary `qwen3.6:27b` (UD-Q6_K_XL). The hybrid
  SSM architecture makes KV ~2.6x cheaper per token than `qwen3-coder:30b`,
  which pays for both the precision upgrade and the larger context.

## VRAM budget

Primary model is `qwen3.6:27b` (27.8B dense, UD-Q6_K_XL, arch `qwen35` —
64 blocks, hybrid attention + state-space). KV cost **cannot be computed from
GGUF metadata**: `qwen35.attention.head_count_kv` is null and the ratio of
full-attention to state-space layers is not exposed. It was measured on the
live pod, 2026-07-30, by loading at two contexts and subtracting:

| Load (q8_0 KV, 2 slots) | `size_vram` |
|---|---|
| `num_ctx` 8192 | 25,113,500,056 B |
| `num_ctx` 98304 | 28,701,727,128 B |

Derived: `(28701727128 − 25113500056) / (2 × 90112)` = **19,910 B/token at
q8_0** → **~37,470 B/token at f16** (×1.882). Sanity: qwen3-coder:30b measured
52,224 B/token q8_0 with the same method.

| Component | Size |
|---|---|
| Card (Tesla V100 32GB) | 31.75 GiB |
| Weights + compute buffers (measured) | 23.09 GiB |
| KV cache, f16 @ 128k x 1 | 4.57 GiB |
| Headroom | ~4.1 GiB |

KV scales as `ctx x slots x 36.6 KiB` at f16. In the same envelope: 96k
(3.43 GiB), 192k (6.86 GiB — fits on paper but extrapolates 2x past the
measured range), 256k (9.15 GiB — over budget).

After any change to context, parallelism, or KV cache type, confirm the model is
entirely on GPU:

    curl -s http://192.168.7.153:11434/api/ps | jq '.models[] | {size, size_vram, context_length}'

`size_vram` must equal `size`. Any gap is CPU offload — reduce context or slots.
Do not fall back to q8_0 KV to close a gap without an explicit decision; dropping
KV precision is what the 2026-07-30 change exists to avoid.

Also check the model-load log line confirms `flash_attn = 1`: the V100 is Volta
(SM70), llama.cpp's newer FA kernels target Turing+, and FA being active there
has only ever been inferred from VRAM numbers, never read from a log
(2026-07-30 session, open question). With f16 KV this is a performance
question, not a correctness one.

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
path, and this dir is a Helm bundle — same split as `06-milvus/attu`). The
parent bundle excludes it via `.fleetignore`, so it is managed solely by its
own `04-ollama/ollama-exporter` path entry in the `lab-ai` GitRepo. It does
two things:

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
