# Physical Host — Hardware Inventory

Node **`sdf1`** — single-node k3s cluster host (openSUSE Leap 16.0, k3s v1.35.5).
Consolidated from a live `hwinfo` / `lspci` / `dmidecode` capture (2026-07). Keep
this current when hardware changes.

## Core platform

| Component | Spec |
|---|---|
| CPU | **AMD Ryzen 7 3700X** — 8C/16T, Zen 2, socket AM4, 65 W TDP (~88 W PPT). PCIe **4.0**. No iGPU. |
| Motherboard | **Gigabyte B550M AORUS PRO** (micro-ATX, B550). BIOS **F20a** (2026-04-14). |
| RAM | **64 GB DDR4** — 4× 16 GB Corsair Vengeance (`CMW32GX4M2D3600C18` / `...Z3600C18`), rated 3600 CL18. **Currently running 2133 MT/s — DOCP/XMP not enabled** (see Tuning backlog). |
| Case | **Thermaltake Core P3 ATX** open-frame (tempered glass, wall-mountable, riser-friendly). Physical room for 2 large GPUs. |
| PSU | **Thermaltake Smart Pro RGB 650 W** (80+ Bronze, modular). **This is the expansion ceiling** — see PSU note. |

## GPUs

| GPU | VRAM | Power | Slot | Link (current) | Role |
|---|---|---|---|---|---|
| **Tesla V100** (GV100GL PG500-216) | 32 GB HBM2 | 250 W | CPU x16 Gen4 (J10) | **PCIe 3.0 x2 — downgraded** (should be x16) | Ollama/Qwen3 inference (`ai` ns); OpenClaw/NemoClaw agent |
| **GeForce GTX 1070** (GP104) | 8 GB | 150 W | Chipset x4 Gen3 (J3708) | **x4 @ 2.5 GT/s (Gen1) — downgraded** | Display output (3700X has no iGPU); formerly ComfyUI |
| **Radeon RX 6600** | 8 GB | — | — | **Physically uninstalled** | none (removed) |

## Storage

- **Boot/NVMe:** Lite-On M8Pe NVMe SSD (`nvme0n1`, PCIe 3.0 x4).
- **SATA SSD:** Samsung 860, SanDisk Extreme.
- **DAS:** JMicron enclosure (`DISK00`–`DISK06`).
- **iSCSI:** multiple IET virtual-disk targets (network storage).
- **Cluster:** Longhorn CSI (~500 Gi) layered on the above.

## Network

- **NIC:** onboard Realtek RTL8111/8168 GbE (`enp5s0`).
- **Overlay:** k3s flannel (`cni0` / `flannel.1`), Tailscale (`tailscale0`), MetalLB L2.
- **Cluster API:** `192.168.7.149:6443`.

## PCIe topology (lspci)

```
CPU  x16 Gen4 (J10)  -> 00:03.1 -> 06:00.0  Tesla V100      [negotiated x2  <-- anomaly]
Chipset switch       -> x4 (J3708) -> 03:00.0 GTX 1070      [negotiated x4 Gen1 <-- anomaly]
CPU  M.2  Gen4       -> Lite-On NVMe
Chipset x1           -> onboard GbE
```

## Tuning backlog (free / no-cost wins)

1. **RAM stuck at 2133 MT/s** — enable DOCP in BIOS. Four dual-rank sticks on B550 realistically land ~3000–3200, not 3600, but that is still a ~40–50 % memory-bandwidth gain → faster CPU-offloaded inference.
2. **Both GPUs under-negotiating** (V100 @ x2, 1070 @ x4/Gen1) — likely a common cause: BIOS PCIe-gen/slot setting or riser signal integrity. Fixing the V100 to x16 mainly speeds **model load time** (in-VRAM inference is insensitive to link width).
3. **PSU is the expansion ceiling** — see below.

## Expansion envelope

- **Board tops out at 2 GPUs:** CPU x16 (Gen4) + chipset x4 (Gen3). Third GPU is out (slots/lanes).
- The open-frame case + riser cables make 2-GPU placement easy; NVLink is possible with **matched** cards at the correct bridge spacing (NVLink bridges join same-family cards only — e.g. V100↔V100 or 3090↔3090, never cross-generation).
- **Binding constraint for any dual-GPU build = the 650 W PSU.** V100 alone ≈ 62 % load; two high-power GPUs (2× 3090 ≈ 850 W peak, or V100 + 3090 ≈ 750 W) require a **1000 W+** unit.
- **Cable note:** Thermaltake modular cables are **not** cross-compatible between PSU models/wattages (pinout differs — reuse can damage hardware). A PSU swap uses the *new* unit's cables.


## Possible upgrades (not planned)

Prices are used/2026 ballparks — verify at purchase.

- **PSU → 1000–1050 W, fully modular, 80+ Gold/Platinum, RGB.** *Prerequisite for any
  dual-GPU build* — the 650 W unit is the ceiling. Keep RGB via an addressable unit
  that syncs to the AORUS board (RGB Fusion). Options by budget:
  - Best value / future-proof: **Thermaltake Toughpower GF A3 1050 W** (ATX 3.1 Gold,
    native 12V-2×6, ~$130) — minimal RGB.
  - Keep RGB, cheaper: a **Gold RGB 1000 W** (Thermaltake GT RGB / Gigabyte AORUS
    P1000W, ~$140–160).
  - Keep RGB, premium: **Thermaltake Toughpower PF1 ARGB 1050 W Platinum** (~$180–230)
    — 18 addressable LEDs, board sync, higher efficiency.
  - **Do NOT reuse the Smart Pro RGB modular cables** — pinout differs between models;
    use the new unit's cables. Only needed alongside a 2nd GPU; not a standalone spend.
- **GPU expansion** (see *Expansion envelope*): 2× RTX 3090 (48 GB NVLink) for one big
  model, or V100 + a 3090 (independent) for flexibility — both gated on the PSU upgrade.
  A single RTX A6000 (48 GB) is the only bigger card that fits the *current* 650 W PSU.
