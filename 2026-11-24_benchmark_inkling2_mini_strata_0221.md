# Final Report: Inkling 2 Mini vs. Qwen3.8-Flash-Next on Strata `0.2.21` (Dell XPS 15 9530)

**Date:** 2026-11-24  
**Decision:** **Stay with `Qwen3.8-Flash-Next` (`IQ3_S` / `IQ3_XXS`)** on the validated `48.4 W` safe preset. `Inkling-2-Mini SQ-10` with DSpark is only **+6.8% faster** in sustained brake-free throughput (`21.74` vs `20.35 t/s`) while offering half the context (`32k` vs `64k`) and substantially lower model capability.

---

## 1. Executive Summary

We upgraded Strata to **`0.2.21`** (`strata-engine 0.1.67`, `strata-inkling 0.1.67`, `control 0.1.67`) and evaluated two quants of **`Inkling-2-Mini`** on a clean cold-boot Dell XPS 15 9530 (`EC reg 0x32 = 0`, no `thermald`, stock BIOS `1.34.0`) against our existing `Qwen3.8-Flash-Next IQ3_S` baselines:

1. **`unsloth/Inkling-2-Mini-UD-Q4_K_M.gguf` (`15.47 GiB`, `32k`, `--draft off`)** — Too large for 8 GB VRAM (~80% of experts spilled to CPU RAM, leaving no room for DSpark). Ran **slower** than `Qwen3.8-Flash-Next IQ3_S` (`21.43 t/s` unbraked, `14.81 t/s` braked) while drawing full hybrid power and hitting the same XPS 15 EC `400 MHz + PCIe Gen 1` brake.
2. **`strata-engine/Inkling-2-Mini-SQ-10.strata` (`9.75 GiB`, native `.strata` with built-in DSpark Block-8, `32k`)** — Major improvement over `UD-Q4_K_M`: fits twice as many experts in VRAM (`1,215` vs `608`), enables **DSpark automatically (`78 MiB`)**, boosts unbraked throughput by **+43%** (`30.62 t/s`, peaking at `35.0 t/s` on `code`), and cuts `agent` TTFT by **2.5×** (`10.68 s` vs `26.80 s`).
   - **Under stock `balanced` power:** Still draws `34.0 W` GPU median (`49.5 W` peak) plus uncapped CPU, hitting the XPS 15 EC `SKIN 59–60 °C / SEN6 65–66 °C` brake from Round 2 onward (`33.9%` of the run at `<= 500 MHz`, `32.4%` active PCIe Gen 1, dropping `r4 prose` to `9.6 t/s`, `20.75 t/s` R2–R4 steady).
   - **Under the validated `48.4 W` safe preset (`GPU <= 1200 MHz`, `VRAM <= 5501 MHz`, `CPU PL1 = 24 W`):** Eliminates the EC brake completely (**`0 / 672 s` active PCIe Gen 1**, `0.4%` single-second `<= 500 MHz` blips), holding a laser-flat **`21.74 t/s` steady** across 6 rounds / 11+ minutes (`R1 21.90` → `R6 22.11 t/s`, `SEN6` max `62.05 °C`, `SKIN` max `59.05 °C`).
3. **Why we stay with `Qwen3.8-Flash-Next`:**
   - **Negligible speed advantage:** `SQ-10` ties `Qwen3.8-Flash-Next IQ3_S` unbraked (`30.62` vs `30.47 t/s`) and gains only **`+1.39 t/s` (`+6.8%`)** in sustained brake-free throughput (`21.74` vs `20.35 t/s`).
   - **Large quality & context gap:** `Qwen3.8-Flash-Next` (125 B / 6 B active, `64k` context, `14–15/20` on PatchEval) is far stronger on real coding and agentic workloads than `Inkling-2-Mini` (`32k` context).
   - **Thermal insight confirmed:** The XPS 15 9530 `SKIN 59 °C / SEN6 62–65 °C` EC ceiling is strictly a **chassis total-power limit (~48–50 W sustained)**, not specific to `Qwen3.8`. Even a 9.75 GB native `.strata` model triggers the exact same EC brake when uncapped, and our `48.4 W` clean-boot cap (`sen6-test-gpu-cpu-cap.sh`) generalizes cleanly across models and engines.

---

## 2. Test Environment & Methodology

- **Machine:** Dell XPS 15 9530 (`i7-13700H`, `RTX 4070 Laptop 8 GB`, `125 GB RAM`, BIOS `1.34.0`, Manjaro KDE, kernel `6.18.63-3-MANJARO`, NVIDIA `620.70.06`, `gpu_unlock` active, lifted ~2 cm, WD22TB4 dock, ~25 °C ambient).
- **Clean-boot thermal baseline:** `EC reg 0x32 = 0`, `INTC10A0:00/uuids/current_uuid = INVALID`, `thermald` disabled, stock `balanced` profile, `SEN6 >= 68 °C` auto-stop safety guard active on all runs (never tripped).
- **Engine:** `strata 0.2.21` (`strata-engine 0.1.67`, `strata-inkling 0.1.67`, `control 0.1.67`), local port `8099`, vision off.
- **Workload:** Standardized 3-prompt loop (`code`, `prose`, `agent` from [`strata-throttle-trace.py`](strata-throttle-trace.py), `max_tokens=700`, `seed=7`), logging per-second `SEN6`, `SKIN`, CPU P-core clocks (`pmax`), GPU watts/clocks, and active PCIe link generation.

---

## 3. Summary Comparison

| Model & Quant | Size | Engine / Drafter | Power Preset (`EC 0x32 = 0`) | Context / KV | Unbraked R1 | Steady / Overall | `<=500 MHz` / Gen 1 | `SEN6` / `SKIN` Max | GPU W (med) |
|---|---:|---|---|---|---:|---:|---:|---|---:|
| `Qwen3.8-Flash-Next IQ3_S` *(ref, `0.2.20`)* | ~60 GB | `strata-engine 0.1.66` + DFlash2 | Stock `balanced` (`68.2 W`) | `64k` / int8 | `30.47 t/s` | `16.06` / `18.96 t/s` | `42.4%` / `256 s` | `65.05 / 60.05 °C` | `34.5 W` |
| **`Qwen3.8-Flash-Next IQ3_S` *(ref, `0.2.20`, recommended)*** | ~60 GB | `strata-engine 0.1.66` + DFlash2 | Safe cap (`48.4 W`: `1200/5501`, `24 W`) | **`64k`** / int8 | `22.2 t/s` | **`20.35`** / `20.62 t/s` | **`0.3%`** / **`0 s`** | `63.05 / 60.05 °C` | `24.4 W` |
| `Inkling-2-Mini UD-Q4_K_M` (`unsloth`) | `15.47 GiB` | `strata-inkling 0.1.67`, `--draft off` | Stock `balanced` | `32k` / int8 | `21.43 t/s` | `14.81` (R2) / `17.51 t/s` | `19.7%` (`58 s`) / `58 s` | `66.05 / 60.05 °C` | `34.3 W` (`45.4 W` pk) |
| `Inkling-2-Mini SQ-10` (`strata-engine`) | `9.75 GiB` | `strata-inkling 0.1.67` + **DSpark** (`78 MiB`) | Stock `balanced` | `32k` / int8 | **`30.62 t/s`** | `20.75` (R2–R4) / `22.57 t/s` | `33.9%` (`148 s`) / `140 s` | `66.05 / 60.05 °C` | `34.0 W` (`49.5 W` pk) |
| `Inkling-2-Mini SQ-10` (`strata-engine`) | `9.75 GiB` | `strata-inkling 0.1.67` + **DSpark** (`78 MiB`) | Safe cap (`48.4 W`: `1200/5501`, `24 W`) | `32k` / int8 | `21.90 t/s` | **`21.74`** (R2–R6) / **`21.77 t/s`** | **`0.4%`** (`3 s`) / **`0 s`** | **`62.05 / 59.05 °C`** | `24.1 W` (`29.1 W` pk) |

---

## 4. Detailed Run Log

### Run 1 — `Inkling-2-Mini-UD-Q4_K_M.gguf` (2026-11-24 22:35, Stock Clean Boot)
- **Model:** `unsloth/Inkling-2-Mini-GGUF` (`Inkling-2-Mini-UD-Q4_K_M.gguf`, `15.47 GiB`)
- **Launch:** `strata-inkling 0.1.67 --max-context 32768 --vram-experts-gb 2.93 --ram-experts-gb 10.85 --draft off`
- **VRAM / Placement:** `7,632 / 8,188 MiB` (`254 MiB` free), trunk `3.29 GB`, `608` GPU / `2,464` CPU host experts (`14.78 GB` pinned RAM), KV `9,216` VRAM + `23,552` host tokens (`1,398 MiB` runner+KV), **`DSpark took 0 MiB`** (`--draft off`). Cold-expert launch probe: CPU lane `61.1 ms/tok` vs GPU copy `128.3 ms/tok` → CPU lane chosen.
- **Per-prompt results (2 rounds):**
  - `r1 code`: **`21.6 t/s`** (`667 tok` in `30.9 s`, TTFT `1.84 s`)
  - `r1 prose`: **`22.3 t/s`** (`687 tok` in `30.8 s`, TTFT `1.91 s`)
  - `r1 agent`: **`20.5 t/s`** (`685 tok` in `33.4 s`, TTFT `26.80 s`)
  - **Round 1 avg:** **`21.43 t/s`** (unbraked)
  - `r2 code`: **`19.5 t/s`** (`668 tok` in `34.3 s`, TTFT `1.94 s`)
  - `r2 prose`: **`9.8 t/s`** (`685 tok` in `69.7 s`, TTFT `1.94 s` — hit XPS 15 EC `400 MHz + PCIe Gen 1` brake)
  - `r2 agent`: **`20.4 t/s`** (`685 tok` in `33.6 s`, TTFT `38.73 s`)
  - **Round 2 avg:** **`14.81 t/s`**
- **Overall (2 rounds):** **`17.51 t/s`** (`4,077 tok` / `232.8 s`).
- **Thermals:** `SEN6` `52.05 → 66.05 °C`, `SKIN` `49.05 → 60.05 °C`, GPU `34.3 W` median (`45.4 W` peak, `1620 / 7001 MHz`), `58 / 294 s` (`19.7%`) at `<= 500 MHz`, `58 / 294 s` active PCIe Gen 1.

---

### Run 2 — `Inkling-2-Mini-SQ-10.strata` (2026-11-24 23:35, Stock Clean Boot)
- **Model:** `strata-engine/Inkling-2-Mini-Strata` (`Inkling-2-Mini-SQ-10.strata`, `10,471,526,400` bytes = `9.75 GiB`, SHA256 verified, native `.strata` with built-in DSpark Block-8)
- **Launch:** `strata-inkling 0.1.67 --serve --native ...Inkling-2-Mini-SQ-10.strata --max-context 32768 --vram-experts-gb 3.25 --ram-experts-gb 4.77 --draft dspark --draft-beam 1 --draft-adapt`
- **VRAM / Placement:** `7,576 / 8,188 MiB` (`314 MiB` free after runner+KV+DSpark), trunk `1.87 GB`, **`1,215` GPU / `1,857` CPU host experts** (`8.60 GB` pinned RAM, adaptive tiering every 4 tok / 16 swaps), KV `11,264` VRAM + `21,504` host tokens (`1,566 MiB` runner+KV), **`DSpark took 78 MiB`** (enabled automatically at `32k`; 128-tok probe measured **`1.12×`** overall: code `1.42×`, chat `0.89×`, plain `27 tok/s`). Cold-expert launch probe: CPU lane **`32.7 ms/tok`** vs GPU copy `50.4 ms/tok` → CPU lane chosen.
- **Per-prompt results (4 rounds, `SEN6 >= 68 °C` guard active — not tripped):**
  - `r1 code`: **`34.0 t/s`** (`671 tok` in `19.7 s`, TTFT `0.82 s`, `0 s` braked)
  - `r1 prose`: **`29.5 t/s`** (`683 tok` in `23.2 s`, TTFT `0.95 s`, `0 s` braked)
  - `r1 agent`: **`28.9 t/s`** (`685 tok` in `23.7 s`, TTFT `10.68 s`, `1 s` `<=500 MHz`)
  - **Round 1 avg:** **`30.62 t/s`** (unbraked)
  - `r2 code`: **`33.4 t/s`** (`669 tok` in `20.1 s`, TTFT `0.94 s`, `0 s` braked)
  - `r2 prose`: **`27.7 t/s`** (`682 tok` in `24.6 s`, TTFT `0.93 s`, `0 s` braked)
  - `r2 agent`: **`14.8 t/s`** (`682 tok` in `46.0 s`, TTFT `16.62 s`, `28 s` `<=500 MHz` / `27 s` Gen 1 — EC brake engaged at `SKIN 59.05 °C`)
  - **Round 2 avg:** **`22.43 t/s`**
  - `r3 code`: **`26.0 t/s`** (`672 tok` in `25.9 s`, TTFT `10.68 s`, `15 s` braked)
  - `r3 prose`: **`19.2 t/s`** (`686 tok` in `35.8 s`, TTFT `0.96 s`, `14 s` braked)
  - `r3 agent`: **`32.7 t/s`** (`686 tok` in `20.9 s`, TTFT `37.02 s`, `23 s` braked during prefill)
  - **Round 3 avg:** **`24.73 t/s`**
  - `r4 code`: **`35.0 t/s`** (`673 tok` in `19.2 s`, TTFT `0.94 s`, `0 s` braked)
  - `r4 prose`: **`9.6 t/s`** (`687 tok` in `71.6 s`, TTFT `0.96 s`, `54 s` `<=500 MHz` / `53 s` Gen 1)
  - `r4 agent`: **`22.1 t/s`** (`681 tok` in `30.8 s`, TTFT `16.06 s`, `13 s` braked)
  - **Round 4 avg:** **`16.78 t/s`**
- **Overall (4 rounds):** **`22.57 t/s`** (`8,157 tok` / `361.5 s`), **R2–R4 steady avg:** **`20.75 t/s`**.
- **Thermals:** `SEN6` `53.05 → 66.05 °C`, `SKIN` `50.05 → 60.05 °C`, GPU `34.0 W` median (`30.9 W` mean, `49.5 W` peak; `1560 / 7001 MHz` med, `1830 / 8001 MHz` max), **`148 / 436 s` (`33.9%`)** at `<= 500 MHz`, **`140 / 432 s` (`32.4%`)** active PCIe Gen 1.

---

### Run 3 — `Inkling-2-Mini-SQ-10.strata` (2026-11-24 23:47, `48.4 W` Safe Preset)
- **Power cap:** [`sen6-test-gpu-cpu-cap.sh`](sen6-test-gpu-cpu-cap.sh) defaults (`GPU <= 1200 MHz`, `VRAM <= 5501 MHz`, `CPU PL1 = 24 W`, `EC reg 0x32 = 0` untouched, `INTC10A0:00/uuids/current_uuid = INVALID`).
- **Engine / Placement:** Same loaded `strata-inkling 0.1.67` instance (`32k`, `7,576 / 8,188 MiB` VRAM, `1,215` GPU / `1,857` host experts, DSpark `78 MiB`).
- **Per-prompt results (6 rounds, 18 prompts, `12,240 tok`, `682 s` span, `SEN6 >= 68 °C` guard active — not tripped):**
  - `R1`: `code` `24.7`, `prose` `20.4`, `agent` `21.1` (TTFT `1.70 / 1.70 / 19.36 s`) → **R1 avg: `21.90 t/s`**
  - `R2`: `code` `24.6`, `prose` `19.2`, `agent` `23.4` (TTFT `1.69 / 1.73 / 19.39 s`) → **R2 avg: `22.14 t/s`**
  - `R3`: `code` `23.5`, `prose` `19.9`, `agent` `22.8` (TTFT `1.73 / 1.72 / 19.30 s`) → **R3 avg: `21.96 t/s`**
  - `R4`: `code` `21.5`, `prose` `18.9`, `agent` `22.4` (TTFT `1.74 / 1.72 / 19.48 s`) → **R4 avg: `20.84 t/s`**
  - `R5`: `code` `24.8`, `prose` `19.2`, `agent` `21.9` (TTFT `1.71 / 1.70 / 19.42 s`) → **R5 avg: `21.73 t/s`**
  - `R6`: `code` `24.7`, `prose` `19.4`, `agent` `23.0` (TTFT `1.71 / 1.71 / 19.44 s`) → **R6 avg: `22.11 t/s`**
- **Overall (6 rounds):** **`21.77 t/s`** (`12,240 tok` / `562.3 s`), **R2–R6 steady avg:** **`21.74 t/s`** (zero degradation: R6 `22.11 t/s` > R1 `21.90 t/s`; worst single prompt `18.9 t/s` vs `9.6 t/s` stock).
- **Thermals:** `SEN6` `54.05 → 62.05 °C` (plateaued at `62.05 °C`), `SKIN` `51.05 → 59.05 °C` (mostly `58.05 °C`), GPU `24.1 W` median (`23.6 W` mean, `29.1 W` peak; locked `1200 / 5501 MHz`), **`3 / 682 s` (`0.4%`)** single-second `<= 500 MHz` blips, **`0 / 672 s` (`0.0%`)** active PCIe Gen 1.

---

## 5. Final Verdict

- **Keep `Qwen3.8-Flash-Next` (`IQ3_S` / `IQ3_XXS`) as the daily local model** paired with `sen6-test-gpu-cpu-cap.sh` (`48.4 W` safe preset) for sustained brake-free inference on the XPS 15 9530.
- **`Inkling-2-Mini SQ-10` is technically clean** (fast startup, compact `9.75 GiB` footprint, working DSpark at `32k`, and `21.74 t/s` steady with zero EC brakes under the `48.4 W` cap), **but `+6.8%` sustained speed does not justify giving up `Qwen3.8-Flash-Next`'s far stronger reasoning/coding quality and `64k` context window**.
