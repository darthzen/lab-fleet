# BIOS Tuning — Gigabyte B550M AORUS PRO (BIOS F20a)

Node **`sdf1`**. Companion to [`HARDWARE.md`](HARDWARE.md). Every change below is
free and reversible; ordered by payoff. Menu labels are approximate — they shift
slightly between BIOS revisions.

## Baseline (captured 2026-07, pre-change)

| Item | Observed | Target | Nature |
|---|---|---|---|
| RAM (4× 16 GB, rated 3600 CL18) | **2133 MT/s** | 3200–3600 | DOCP/XMP off |
| Tesla V100 (CPU x16 slot, **on a riser**) | Gen3 (8 GT/s) **× x2** | Gen3 x16 | width downtrain — riser |
| GTX 1070 (chipset x4 slot) | **Gen1 (2.5 GT/s)** x4 | Gen3 x4 | speed downtrain — BIOS |

## 1. Memory profile (DOCP/XMP) — the big free win

- **Where:** `Tweaker` → **Extreme Memory Profile (X.M.P.)** → **Profile 1**
  (Gigabyte labels DOCP as "XMP" on recent BIOS; it reads the Corsair 3600 CL18 profile).
- **Why:** RAM is at the JEDEC floor of 2133 MT/s. The profile targets 3600 — a
  ~40–50 % memory-bandwidth jump that directly speeds any CPU-offloaded inference
  (models spilling past VRAM) and general node responsiveness.
- **Catch:** 4× dual-rank is the hardest config on B550, so 3600 may not POST stably.
  Fallback ladder:
  1. Try Profile 1 (3600).
  2. If unstable → set **3200** (or 3000) manually, keeping **Infinity Fabric (FCLK)
     1:1**: FCLK = memclk ÷ 2 (1600 MHz for DDR4-3200).
  3. Only nudge SoC/VDDG/VDDP if 3200 still isn't clean.
- **Verify:** `sudo dmidecode -t memory | grep "Configured Memory Speed"` +
  `stressapptest -s 300` (or memtest).

## 2. PCIe links — two *separate* problems

- **GTX 1070 at Gen1 → BIOS fix.** Speed is capped, not physical.
  `Settings` → `IO Ports` (or `Miscellaneous`) → **PCIe Slot Configuration** → set the
  chipset slot to **Auto** (or Gen3). (x4 width is correct — that is all the chipset
  slot provides.)
- **Tesla V100 at x2 *width* → physical (the riser), NOT a BIOS knob.** Its speed is
  already Gen3; only the width is wrong.
  - **Bifurcation on this board offers only `Auto / 2×8 / 1×8+2×4 / 4×4`.** Use **Auto**
    (= full x16 to a single card). Note the floor of every split mode is x4 — **none can
    produce x2**, which confirms the fault is the riser, not the BIOS.
  - **Fix:** replace the ribbon with a **shielded, PCIe 4.0-rated x16 riser** (buy Gen4
    even though the V100 is Gen3 — it carries forward to a future 3090/4090 on that
    mount). Good options: LINKUP, Thermaltake TT Premium PCIe 4.0, ADT-Link. Shortest
    length that reaches. Interim free test: reseat both riser ends, or seat the card
    directly in the slot to confirm x16.
  - **Stakes:** x2 only slows model *loading*, not inference throughput — tidy-up, not urgent.

## 3. GPU hygiene toggles

- **Above 4G Decoding → Enabled** (`Settings` → `IO Ports`). Needed for large-BAR
  compute GPUs + multi-GPU. Likely already on (V100 works) — confirm.
- **Re-Size BAR Support → Enabled** (requires Above 4G on + CSM off). Small, free.
- **CSM Support → Disabled** (`Boot`). UEFI-only; prerequisite for Resizable BAR. Safe
  here (box already boots UEFI / openSUSE).
- **IOMMU → Enabled/Auto** — already active; leave it.

## 4. Future dual-GPU note (do nothing now)

- A 2nd GPU goes in the chipset x4 slot → no bifurcation needed (separate slots).
  x8/x8 off the CPU would need bifurcation support + a bifurcation riser — and NVLink
  makes that unnecessary by carrying GPU-to-GPU traffic off the bus.

## Verify after changes

```bash
sudo dmidecode -t memory | grep "Configured Memory Speed"   # RAM at 3200/3600
sudo lspci -vvnn | grep -A2 'GV100' | grep LnkSta            # V100 -> Width x16
sudo lspci -vvnn | grep -A2 'GP104' | grep LnkSta            # 1070 -> Speed 8GT/s
```

## Order of operations & safety

1. **DOCP first** (biggest win, most iteration) → reboot → verify RAM.
2. Then PCIe-gen + GPU toggles together → reboot → verify links.
3. The V100 riser swap is independent (hardware, not BIOS).
4. Change **one group at a time**, note prior values. A failed memory profile may need a
   **CMOS clear** (clear-CMOS jumper on the board) — then step down the ladder.
