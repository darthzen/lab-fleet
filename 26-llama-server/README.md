# 26 — llama.cpp server: Qwen3.8-Flash-Next on both V100s

    kubectl apply -f llama-server.yaml

Upstream `ghcr.io/ggml-org/llama.cpp` `server-cuda` image (pinned by digest)
serving `unsloth/Qwen3.8-Flash-Next-GGUF` at **UD-IQ4_XS** from a hostPath on
the 9100 PRO NVMe. GPU access is by `runtimeClassName: nvidia` plus an explicit
`NVIDIA_VISIBLE_DEVICES` pair of UUIDs — **not** a device-plugin
`nvidia.com/gpu` request, which would let the plugin pick GPUs and could hand
out the GTX 1070.

OpenAI-compatible API at `http://192.168.7.165:8080/v1`; llama.cpp's own web UI
at `/`; Prometheus metrics at `/metrics`. Model alias is `qwen3.8-flash-next`.

**This displaces 04-ollama and 07-comfyui**, both declared at 0 replicas while
it runs. Decided 2026-09-20. To go back: set `replicas: 0` here, then
`replicaCount: 1` in `04-ollama/values.yaml` and `replicas: 1` in
`07-comfyui/comfyui.yaml`. Fleet is the source of truth for all three numbers.

## What the model is

An experimental preview of the Qwen4 architecture (`qwen4exp`), released
2026-08-26. 125B-parameter MoE language model (512 experts per layer, 10 routed
+ 1 shared, ~6B active per token), plus a **51B n-gram embedding table** — a
lookup indexed by the last two or three tokens, applied at layer 2 — plus a 4B
multi-token-prediction head. The table is the reason a 180B-parameter model runs
here: it does no arithmetic, its rows are ~90 bytes, and only the rows a token
touches are ever read, so it can stay on disk behind a memory map.

Sizes measured from the GGUF headers (decimal GB):

| Quant | File | Routed experts | N-gram table | Always-on |
|---|---|---|---|---|
| UD-IQ3_XXS | 81.3 | 48.0 | 28.8 | 4.4 |
| UD-IQ4_XS | 93.7 | 59.5 | 28.8 | 5.3 |
| **UD-Q4_K_XL** | **111.3** | **77.0** | **28.8** | **5.5** |

The table is IQ4_NL in every unsloth quant (they do not go below 4-bit on it).
Only the experts change size, so the experts decide the quant.

## Memory budget (2026-09-20)

- VRAM: 2 × 34.4 GB = 68.7 GB. ~4 GB per card held back for CUDA context,
  compute buffers and the 64k q8_0 KV cache → ~60 GB for weights.
- IQ4_XS wants 64.8 GB on-device (experts + always-on), so ~10.6 GB of
  experts live in host RAM: `--n-cpu-moe 8` (8 of 48 layers at ~1.19 GB) with
  `--tensor-split 28,20`. Card 0 carries ~5 GiB of KV/compute buffers on top
  of its weights, so it gets the lighter share.
- History: Q4_K_XL ran first (2026-09-20) at `--n-cpu-moe 18`,
  `--tensor-split 33,15` — 102 tok/s prompt processing, 22–24 tok/s decode —
  and the latency showed in use. It stays on disk if quality ever outweighs
  speed. The first XL attempt (N=14, no tensor split) OOMed card 1 at
  37.8 GiB: llama.cpp splits layers by count, not bytes.
- Host RAM: 62 GiB, ~46 GB free with ollama and comfyui parked. The CPU-side
  experts and the paged-in table rows are all file-backed under `mmap`; the
  56Gi cgroup limit is there so reclaim never thrashes the map.
- The GTX 1070 (8 GB, Pascal) is deliberately excluded from the pin.

## Tuning order, from the load log

1. `--n-cpu-moe` — the first knob. Raise if a card OOMs at load; lower while
   nvidia-smi shows per-card headroom, and recompute `--tensor-split` with it
   (k ≈ N + (48 − N)/2, then check bytes with the per-layer sizes in the GGUF
   header — the UD quants keep layers 2/4/30/46/47 at higher precision).
2. `--ctx-size` — 65536 is the hermes floor, not the ceiling; KV on this
   hybrid-attention arch is small.
3. MTP speculative decoding (`--spec-type draft-mtp -md
   /models/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf`) — the head is
   downloaded, but the code is a draft upstream PR (ggml-org/llama.cpp#27836)
   and needs the `danielhanchen/llama.cpp` `qwen4exp/mtp` branch, i.e. a BCI
   rebuild through lab-image-build. Community reports 13–61% decode gain
   GPU-resident.
4. Volta flash-attention: upstream runs SM 7.0 on the generic head-256 kernel
   config; the sm70-specific one is draft PR #27997. Works, slower at long
   context.

## Host side

Model files are pulled onto sdf1 by
`/var/lib/models/qwen3.8-flash-next/download.sh` (resumable `curl`, logs to
`download.log` alongside). The pod's init container waits until every IQ4_XS
shard matches its exact byte size from the Hugging Face tree API, so a pod
scheduled before the download finishes simply waits rather than CrashLooping.

The first start also JIT-compiles the image's PTX for SM 7.0 (the CUDA 12.8
image ships `70-virtual`, not a Volta binary). `CUDA_CACHE_PATH` points at a
hostPath (`/var/lib/models/.nv-cache`) so that cost is paid once, not per
restart. The startup probe allows an hour.

Host driver is 580.x (CUDA 13.0). A CUDA 13 **toolkit** cannot build for Volta;
CUDA 12.x binaries still run. Any rebuild must use a 12.x toolkit with
`-DCMAKE_CUDA_ARCHITECTURES=70`.

## Sampling

Server defaults are unsloth's thinking-mode settings (temp 1.0, top_p 0.95,
top_k 20, min_p 0). Instruct-style callers should send temp 0.7, top_p 0.8,
presence_penalty 1.5. `reasoning_effort` defaults to `medium` via
`--chat-template-kwargs`; per-request override through `chat_template_kwargs`.
