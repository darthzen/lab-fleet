# 04 — Ollama (otwld/ollama-helm)

    helm repo add ollama-helm https://helm.otwld.com/
    helm upgrade --install ollama ollama-helm/ollama --version 1.67.0 -n ai --create-namespace -f values.yaml

Key choices: Tesla V100 (32 GB) pinned by GPU UUID; flash attention + q8_0 KV
cache to fit useful contexts; `OLLAMA_CONTEXT_LENGTH=98304` (96k) with
`OLLAMA_NUM_PARALLEL=2`; LoadBalancer at `192.168.7.153:11434` so LAN clients
(Claude Code via ollama-code-mcp, the Xcode instance) reach it directly. 200Gi
Longhorn PV for models.

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

## VRAM budget

Primary model is `qwen3-coder:30b` (30.5B MoE, Q4_K_M, 48 layers, 4 KV heads,
head_dim 128 → 49152 KV elements/token).

| Component | Size |
|---|---|
| Card (Tesla V100 32GB) | 31.75 GiB |
| Weights | 17.3 GiB |
| KV cache, q8_0 @ 96k x 2 | 9.56 GiB |
| Compute buffers (estimated) | ~1.0 GiB |
| Headroom | ~3.3 GiB |

q8_0 costs 51 KiB/token, so KV scales as `ctx x slots x 51 KiB`. Alternatives in
the same envelope: 112k x 2 (11.16 GiB), 128k x 2 (12.75 GiB, no headroom),
64k x 3 (9.56 GiB). Dropping KV to f16 doubles every figure above and will not
fit.

After any change to context, parallelism, or KV cache type, confirm the model is
entirely on GPU:

    curl -s http://192.168.7.153:11434/api/ps | jq '.models[] | {size, size_vram, context_length}'

`size_vram` must equal `size`. Any gap is CPU offload — reduce context or slots.

## Upgrade procedure

Scale to zero first. On 2026-07-16 an in-place change wedged the old ollama
process, which ignored SIGTERM and took the V100 off the bus ("GPU is lost",
`nvidia-smi` hung on sdf1). Force-deleting the stuck pod then produced a
~250-pod `UnexpectedAdmissionError` ReplicaSet storm.

    kubectl --context default -n ai scale deploy/ollama --replicas=0
    kubectl --context default -n ai rollout status deploy/ollama --timeout=180s
    helm --kube-context default upgrade --install ollama ollama-helm/ollama \
      --version 1.67.0 -n ai -f values.yaml

`helm list` looks empty for sdf1 releases unless you pass `--kube-context default`
— the Mac defaults to the `rancher` context (khyron).

## Fleet

`fleet.yaml` sets `takeOwnership: true` and Fleet watches this bundle. If Fleet
syncs from git before a manual `helm upgrade`, Fleet applies the change and the
manual command becomes a no-op. Decide which one is driving before running either.
