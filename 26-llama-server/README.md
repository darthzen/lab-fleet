# 26 — llama.cpp server: Qwen3.8-27B-Uncensored (Q8_0 + MTP) on both V100s

    kubectl apply -f llama-server.yaml

Upstream `ghcr.io/ggml-org/llama.cpp` `server-cuda` image (pinned by digest,
build b11058) serving `mradermacher/Qwen3.8-27B-Uncensored-GGUF` at **Q8_0**
(the orcarouter abliteration of Qwen3.8-27B) from a hostPath on the 9100 PRO
NVMe (`/var/lib/models`). GPU access is by `runtimeClassName: nvidia` plus an
explicit `NVIDIA_VISIBLE_DEVICES` pair of UUIDs — **not** a device-plugin
`nvidia.com/gpu` request, which would let the plugin pick GPUs and could hand
out the GTX 1070.

OpenAI-compatible API at `http://192.168.7.165:8080/v1`; llama.cpp's own web UI
at `/`; Prometheus metrics at `/metrics`. Model alias is
`qwen3.8-27b-uncensored`.

**This displaces 04-ollama and 07-comfyui**, both declared at 0 replicas while
it runs. Decided 2026-09-20. To go back: set `replicas: 0` here, then
`replicaCount: 1` in `04-ollama/values.yaml` and `replicas: 1` in
`07-comfyui/comfyui.yaml`. Fleet is the source of truth for all three numbers.

## History

| Date | Model | Why |
|---|---|---|
| 2026-09-20 | Qwen3.8-Flash-Next (unsloth UD-Q4_K_XL → UD-IQ4_XS → mradermacher uncensored IQ4_XS) | Try the 125B MoE preview. See "Flash-Next" below — everything needed to run it again is there. |
| 2026-09-22 | **Qwen3.8-27B-Uncensored Q8_0** (mradermacher) | Rick: back to the 27B, uncensored. Served here rather than by 04-ollama because llama-server can do things Ollama cannot (next section). |

## Why llama-server for the 27B and not Ollama

04-ollama already ran this model with MTP, flash attention, f16 KV, 131k
context and keep-alive forever, so raw decode speed is close. The gains are
the things Ollama has no knob for:

- **Two slots sharing one KV window** (`--parallel 2 --kv-unified`). A lone
  Hermes turn can use the whole 262k pool; two clients share it. Ollama
  reserves a full window per slot, which is why it ran one slot and queued.
- **Prompt cache in host RAM** (`--cache-ram 16384`). A slot handed to another
  client parks its KV state and restores it on the next turn. Ollama
  recomputes the prefix.
- **Tunable MTP depth** (`--spec-draft-n-max`, 1–6). Ollama fixes it in the
  tag. Low-temperature precise sampling raises acceptance.
- **Prompt-processing batch 2048/512** (Ollama: 512) — time to first token on
  a long Hermes preamble.
- **Reasoning control per request** — `reasoning_effort` via
  `chat_template_kwargs`, `--reasoning-budget`, thought/content separation.
- **Context honoured on `/v1`.** Ollama ignores per-request `num_ctx` there.

## What the model is

Qwen3.8-27B: dense 27.3B, arch `qwen35` — 64 blocks, hybrid Gated DeltaNet /
full attention at a 1:4 interval (`qwen35.full_attention_interval 4`), 4 KV
heads, native context 262144, plus a one-block multi-token-prediction head
(`qwen35.nextn_predict_layers 1`, tensors `blk.64.nextn.*`). Read from the
GGUF header on 2026-09-22; mradermacher's Q8_0 carries exactly the same 866
tensors as unsloth's, so the MTP head is present. orcarouter's own GGUF repo
is gated (`gated: auto`), which is why mradermacher's is the source.

Abliteration (orcarouter, refusal-direction orthogonalization) is the same
treatment as the Flash-Next uncensored quant. No quality evaluation has been
done on this box — the Ollama tag ran the base model.

## Memory budget (2026-09-22, derived — confirm from the load log)

- Weights: 29.0 GB decimal (Q8_0, incl. the 1.3 GB output head and the MTP
  block).
- KV: **64 KiB/token at f16** on this arch (measured from Ollama's load log,
  2026-07-30/09-03; `head_count_kv` alone cannot be used because the hybrid
  layer ratio is what sets it). 262144 ctx → 16 GiB, one unified pool.
- Compute / MTP buffers: ~5 GiB, mostly on card 0.
- Total ≈ 50 GB of 64 GiB. Ollama measured 47 GB for the same model at 262k,
  one slot.
- `--tensor-split 30,35`: card 0 ≈ 13.4 GB weights + 7.4 GiB KV + buffers;
  card 1 ≈ 15.6 GB weights + 8.6 GiB KV. Rebalance if either card sits above
  29 GiB after load.
- Host RAM: 62 GiB. The mapped file is page cache (reclaimable); the prompt
  cache is up to 16 GiB anonymous. Pod limit 40Gi.
- The GTX 1070 (8 GB, Pascal) is deliberately excluded from the pin.

## Measurements

Filled in after the first load on 2026-09-22 (see the load log for the KV
line and `nvidia-smi` for per-card use). Benchmarks are `/v1/chat/completions`
`timings` on a warm slot:

| Config | pp tok/s | tg tok/s | card 0 / card 1 GiB |
|---|---|---|---|
| layer split, MTP n-max 2 | _pending_ | _pending_ | _pending_ |
| layer split, MTP off | _pending_ | _pending_ | |
| row split, MTP n-max 2 | _pending_ | _pending_ | |

## Tuning order

1. `--spec-draft-n-max` — try 1–6; the optimum is hardware-specific
   (unsloth's guidance). Watch `/metrics` draft acceptance.
2. `--split-mode row` A/B — dense model, PCIe-only cards (PHB, no NVLink).
   Keep whichever wins decode without hurting prompt processing.
3. `--tensor-split` — from the measured per-card use, not from the derivation
   above.
4. Volta flash-attention: upstream runs SM 7.0 on the generic head-256 kernel
   config; the sm70-specific one is draft PR #27997. Works, slower at long
   context.

## Sampling

Server defaults are the **precise coding profile** (temp 0.15, top_p 0.9,
top_k 20, min_p 0, presence 0, repeat 1.0) — the same numbers as the
04-ollama `qwen3.8:27b-mtp-q8-precise` tag, chosen after the fossa-mcp
hallucination incident. Chat-style callers can send unsloth's thinking
defaults (temp 1.0, top_p 0.95, top_k 20) per request. `reasoning_effort`
defaults to `medium` via `--chat-template-kwargs`; override per request
through `chat_template_kwargs` (`xhigh`, `medium`, `low`, `none`).

## Host side

Model files are pulled onto sdf1 by a `download.sh` next to each model
directory under `/var/lib/models` (resumable `curl`, logs to `download.log`
alongside). The pod's init container waits until the model file matches its
exact byte size from the Hugging Face tree API, so a pod scheduled before the
download finishes simply waits rather than CrashLooping.

The first start also JIT-compiles the image's PTX for SM 7.0 (the CUDA 12.8
image ships `70-virtual`, not a Volta binary). `CUDA_CACHE_PATH` points at a
hostPath (`/var/lib/models/.nv-cache`) so that cost is paid once, not per
restart. The startup probe allows an hour.

Host driver is 580.x (CUDA 13.0). A CUDA 13 **toolkit** cannot build for Volta;
CUDA 12.x binaries still run. Any rebuild must use a 12.x toolkit with
`-DCMAKE_CUDA_ARCHITECTURES=70`.

On disk (`/var/lib/models`, 2026-09-22):

| Directory | Contents |
|---|---|
| `qwen3.8-27b-uncensored/mradermacher-Q8_0/` | **current** — 29.0 GB, one file |
| `qwen3.8-flash-next-uncensored/mradermacher-IQ4_XS/` | Flash-Next uncensored, 98.4 GB |
| `qwen3.8-flash-next/{UD-Q4_K_XL,UD-IQ4_XS,MTP}/` | Flash-Next unsloth quants + MTP head, 194 GB |

## Flash-Next (parked, 2026-09-20 → 09-22)

Everything needed to run it again. An experimental preview of the Qwen4
architecture (`qwen4exp`): 125B MoE (512 experts per layer, 10 routed + 1
shared, ~6B active) plus a **51B n-gram embedding table** looked up by the
last two or three tokens, plus a 4B MTP head. The table does no arithmetic and
is read a few ~90-byte rows per token, so it stays on disk behind a memory map
(`--override-tensor per_layer_token_embd=CPU`); that is the whole reason a
180B-parameter model ran here.

Sizes from the GGUF headers (decimal GB):

| Quant | File | Routed experts | N-gram table | Always-on |
|---|---|---|---|---|
| unsloth UD-IQ4_XS | 93.7 | 59.5 | 28.8 | 5.3 |
| unsloth UD-Q4_K_XL | 111.3 | 77.0 | 28.8 | 5.5 |
| mradermacher IQ4_XS (uncensored) | 98.4 | 66.4 | 28.8 | 3.3 |

Placements that ran (all 2026-09-20), each an args change:

| Quant | `--n-cpu-moe` | `--tensor-split` | pp / tg tok/s |
|---|---|---|---|
| UD-Q4_K_XL | 18 | 33,15 | 102 / 22–24 |
| UD-IQ4_XS | 8 | 28,20 | 170 / 27–28 |
| mradermacher IQ4_XS | 9 | 28,20 | 220 / 33–34 |

Plus `--ctx-size 65536`, q8_0 KV, `--load-mode mmap`, memory limit 56Gi (the
CPU-side experts are file-backed), and the memory budget rule: llama.cpp splits
layers by *count*, card 0 carries ~5 GiB of KV/compute buffers, so
k ≈ N + (48 − N)/2 and then check bytes per card from the per-layer sizes in
the header (targets card 0 ≤ 27.5 GB, card 1 ≤ 30 GB). The first XL attempt
with an even split OOMed card 1 at 37.8 GiB. Flash-Next's MTP head needs the
`danielhanchen/llama.cpp` `qwen4exp/mtp` branch (draft PR #27836), i.e. a BCI
rebuild via lab-image-build — never done.
