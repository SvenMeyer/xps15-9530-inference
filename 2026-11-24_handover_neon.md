# Handover & Reference Guide: Dell XPS 15 9530 `SEN6` / `SKIN` Thermal Ceiling (`neon`)

**Date:** 2026-11-24 (22:05 AEDT)  
**Workspace:** `/home/sum/Downloads/AI-Runtime`  
**Git branch:** `xps15-sen6-research` (tracking `origin/xps15-sen6-research` → `https://github.com/SvenMeyer/xps15-9530-inference.git`, **PUBLIC repo**)  
**System state:** **100% stock & clean** (`thermald.service` disabled & stopped, `INTC10A0:00/uuids/current_uuid = INVALID`, `EC reg 0x32 = 0`, `PL1_msr = PL1_mmio = 115 W`, GPU clocks unlocked/default, `platform_profile = balanced`, kernel `6.18.63-3-MANJARO`, NVIDIA `620.70.06`, BIOS `1.34.0`, Strata `0.2.20`).

---

## 1. Executive Conclusion & Hardware Decision

We completed full clean-boot verification after a cold shutdown and mapped the laptop's exact sustained thermal ceiling:

1. **The hardware cooling envelope — not a Linux bug or VRM fault — is the hard ceiling.**
   - Pre-brake `~29–30 t/s` on Qwen3.8-Flash-Next `IQ3_S` requires **`~68 W` combined** (`33.7 W` CPU + `34.5 W` GPU).
   - On a clean cold boot (`EC reg 0x32 = 0`, no Intel DTT `_OSC` handoff), Dell's EC legacy fallback enforces a **2-step power cliff (`12.0 W / PCIe Gen 4` → `9.3 W / 400 MHz / PCIe Gen 1`)** whenever **`SKIN >= 59.05 °C`** and **`SEN6 >= 62.05–65.05 °C`** (releasing every time at **`SEN6 = 61.05 °C`**, 29/29 completed brakes across all traces).
   - With internal fans alone (even lifted ~2 cm, even on `performance` `6300 / 6000 RPM` fans), any `>= 50 W` combined load still kisses `SKIN = 59.05 °C / SEN6 = 63.05 °C`. Only dropping combined `CPU + GPU` power to **`~48 W`** (specifically trimming GPU draw, which heats `SEN6` at `0.41 °C/W` vs CPU's `0.19 °C/W`) avoids the EC brake cleanly.
2. **User decision (hardware longevity first):**
   - Because this laptop is out of warranty and sustained max-power local AI stresses the charger/chassis thermals, **do NOT push the machine to its thermal edge permanently or install `thermald`**.
   - Keep the machine **100% stock** for everyday use, and use the validated **safe on-demand clean-boot preset (`48.4 W` total, `20.35 t/s` steady, `+27%` over unmitigated `16.06 t/s`, `0` full EC brakes, `0 s` PCIe Gen 1, stock EC safety untouched)** whenever running a longer local inference session.

---

## 2. How to Use, Secure & Maintain the Best Safe Setting (On-Demand, Clean Boot)

### Daily Usage (1 Command, Zero Persistent System Changes)
When starting a longer Strata / local-LLM session, open a terminal and run:

```bash
sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh
```

- **Validated defaults built into [sen6-test-gpu-cpu-cap.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh):**
  - `GPU core max`: **`1200 MHz`** (`nvidia-smi -lgc 210,1200`)
  - `GPU VRAM max`: **`5501 MHz`** (`nvidia-smi -lmc 405,5501`) — drops GPU draw from `34.5 W` → **`~24.4 W`** (note: GPU runs at PCIe Gen 3 in this P-state; `0 s` at Gen 1)
  - `CPU PL1` (`intel-rapl:0` & `intel-rapl-mmio:0`): **`24 W`**
  - `max_secs`: **`0`** (runs until you press `Ctrl-C`)
  - **Does NOT start `thermald` or call `_OSC` / `DPST(1)`** → `EC reg 0x32` remains `0` and all stock hardware protections stay 100% active.
- **Measured performance ([strata-throttle-trace-20261124-2141-1-balanced.jsonl](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2141-1-balanced.jsonl)):**
  - **`20.35 t/s` steady** (R4–R8; `20.62 t/s` overall R1–R8) vs `16.06 t/s` unmitigated (`+27%`), **`0` full EC brakes**, **`0 s` PCIe Gen 1**, only `0.3%` (`2 s` / `796 s`) `<= 500 MHz`.
  - Combined draw **`48.4 W`** (`24.0 W` CPU + `24.4 W` GPU) — ~20 W cooler than stock `68.2 W`!
- **Stopping / Rollback (instant):**
  - Press **`Ctrl-C`** in that terminal (or simply reboot). The exit trap automatically runs `nvidia-smi -rgc`, `nvidia-smi -rmc`, and restores `PL1_msr = PL1_mmio = 115 W`.
- **Verification (non-sudo, anytime):**
  ```bash
  cat /sys/bus/platform/devices/INTC10A0:00/uuids/current_uuid \
      /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw \
      /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
  nvidia-smi --query-gpu=power.draw,clocks.gr,clocks.mem,pcie.link.gen.current --format=csv
  ```
  - Stock idle should show `INVALID`, `115000000`, `115000000`, and `210 / 405 MHz`.
- **Maintenance across Manjaro / kernel / NVIDIA updates:**
  - Nothing is installed in `/etc` or `/etc/systemd/system`, so OS/kernel updates cannot break boot or conflict with it.
  - Only check if a future NVIDIA driver changes `-lgc` / `-lmc` syntax (the script checks for errors and exits cleanly if either fails).
  - If you ever want a *slightly* cooler margin (e.g., on a >28 °C summer day), lower CPU PL1 by 2 W on the command line without editing the script:
    ```bash
    sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh 1200 22 0 5501
    ```

---

## 3. Complete 2026-11-24 Clean-Boot Experimental Results

All runs below were performed on a **verified clean cold boot (`EC reg 0x32 = 0`)** on kernel `6.18.63-3-MANJARO`, NVIDIA `620.70.06`, BIOS `1.34.0`, Strata `0.2.20` (`Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S`, 64k, DFlash2, `STRATA_ROUTE_TAIL_SKIP=0`, `STRATA_ROUTE_PRIOR=1.5`, `conversation-spill-mib=0`), lifted ~2 cm, WD22TB4 dock, battery 100% (`Not charging`):

| Test / Trace File | CPU + GPU W | Total W | GPU Clocks | Fans (RPM) | `SEN6` / `SKIN` Max | `<=500 MHz` % | PCIe Gen 1 | Steady t/s | Overall t/s |
|---|---:|---:|---|---|---|---:|---:|---:|---:|
| Baseline unmitigated `balanced` ([1849](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-1849-1-balanced.jsonl)) | `33.7 + 34.5 W` | `68.2 W` | `1485 / 7001` | `5900 / 5600` | `65.05 / 60.05 °C` | `42.4%` (5 brakes) | `256 s` | `16.06` | `18.96` |
| `thermald` `63C→22W` ([fail telemetry](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom22w-cleanboot-fail-telemetry.txt)) | `32–40 W` (56 s lag) + `~34 W` | `~68 W` | `1485 / 7001` | `5900 / 5600` | `64.05 / 59.05 °C` | `~55%` (11 brakes in 15 min) | *(not logged)* | `~12–14` | *(aborted at 15 min)* |
| `thermald` `59C→20W / 63C→17W` ([2013](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2013-1-balanced.jsonl)) | `17.0 + 33.8 W` | `50.8 W` | `1485 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `27.0%` (9 brakes) | `214 s` | `15.4` | `17.9` |
| A1: `GPU<=1200`, `CPU=22W` ([2042](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2042-1-balanced.jsonl)) | `22.1 + 28.7 W` | `50.8 W` | `1200 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `18.9%` (7 brakes) | `133 s` | `18.54` | `20.35` |
| A2: `GPU<=960`, `CPU=22W` ([2059](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2059-1-balanced.jsonl)) | `22.1 + 27.4 W` | `49.5 W` | `960 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `19.8%` | `148 s` | `17.99` | `19.24` |
| A4: `GPU<=960`, `CPU=22W`, `perf` ([2117](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2117-1-performance.jsonl)) | `22.0 + 28.0 W` | `50.0 W` | `960 / 7001` | `6291 / 6003` | `63.05 / 59.05 °C` | `19.0%` | `138 s` | `18.45` | `19.25` |
| **A3: `GPU<=1200`, `VRAM<=5501`, `CPU=24W` ([2141](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace-20261124-2141-1-balanced.jsonl))** | **`24.0 + 24.4 W`** | **`48.4 W`** | **`1200 / 5501`** | **`5900 / 5600`** | **`63.05 / 60.05 °C`** | **`0.3%` (`0` full brakes)** | **`0 s`** | **`20.35`** | **`20.62`** |

### Key Technical Lessons Learned (Do Not Re-Discover)
- **Cold shutdown clears `EC reg 0x32`:** Confirmed by Step 2 (`1849`).
- **Intel RAPL PL1 `55.97 s` averaging window (`constraint_0_time_window_us = 55967744`):** Setting `PL1_mmio` dynamically at `SEN6 = 63 °C` is ~30–40 s too late; the CPU keeps drawing `32–40 W` until the EC brake trips.
- **`thermald` XML trip deduplication:** Two `<type>passive</type>` trips on the same zone overwrite each other (`updating existing trip temp`). A second tier on the same zone must use `<type>max</type>` (type 2), which `<Preference>QUIET</Preference>` also evaluates.
- **2-step clean-boot EC fallback:** In `2013`, we caught the EC clamping CPU first to **`12.0 W` (`500–600 MHz`, PCIe Gen 4)** and then escalating to **`9.3 W` (`400 MHz`) + PCIe Gen 1**. Across all 30 recorded JSONL brakes, **30/30** started with `SKIN = 59.05–60.05 °C` (`SEN6 = 62.05–66.05 °C`) and **29/29** completed brakes released at **`SEN6 = 61.05 °C`**.
- **NVIDIA RTX 4070 Laptop clock/power facts:** `nvidia-smi -pl` is blocked by VBIOS, but `-lgc` and `-lmc` both work at runtime. Below `~1000 MHz` core, the GPU hits its voltage floor (`28.7 W` at `1200 MHz` vs `27.4 W` at `960 MHz`); dropping VRAM `7001 → 5501 MHz` saves the additional `~4–5 W` (`~24.4 W` at `1200/5501 MHz`).

---

## 4. Future Upgrade Paths (If You Ever Want to Squeeze More Out Later)

### Future Option 1 — Active Underside Cooling (Safest Path to `~28–30 t/s` Sustained)
- **Why it works:** Directly cools the bottom chassis (`SKIN`) and charger board area (`SEN6` / `QE10`) without weakening any firmware protection (`EC reg 0x32` stays `0`, zero software hacks). Dropping `SKIN`/`SEN6` by `4–6 °C` lets the laptop sustain its full **`~68 W` (`34 W` CPU + `34.5 W` GPU = `29–30 t/s`)** without hitting `SKIN = 59 °C` or `SEN6 = 62–65 °C`.
- **Hardware:** Sealed-foam high-static-pressure laptop cooler (e.g., IETS GT500 / Llano-style pad) or even a simple desk fan blowing across the underside of the lifted laptop.
- **Quick 10-minute verification protocol (NO `sudo` required):**
  1. Place laptop on active cooler / point fan underneath (stock `115 W` PL1, stock GPU clocks, `thermald` stopped).
  2. Run a single guarded `balanced` trace:
     ```bash
     cd /home/sum/Downloads/AI-Runtime
     TRACE_ROUNDS=8 bash <(sed 's/^ARMS=.*/ARMS="balanced"/' strata-throttle-trace.sh)
     ```
  3. **Success check:** `0 s` at `400 MHz`, `0 s` PCIe Gen 1, `SEN6 <= 61 °C`, `SKIN <= 57 °C`, steady decode `~28–30 t/s`. If `SEN6` still nears `62–63 °C`, combine with a mild GPU core cap (`sudo ./sen6-test-gpu-cpu-cap.sh 1200 32 0 0`, keeping full `7001 MHz` VRAM!).

### Future Option 2 — Windows-Style `DPST(1)` Handoff + Custom `thermald` (Target `~25–28 t/s`, No Extra Hardware)
- **Why it works:** On Windows, Dell's official Intel DTT (`INTC10A0:00/data_vault`) calls `IETM._OSC` → `ECDV.DPST(1)` (`EC reg 0x32 = 1`), disabling the EC's legacy coarse `62–65 °C / 400 MHz + PCIe Gen 1` fallback so OS thermal control can smoothly regulate CPU PL1 (using Dell's Windows GDDV limits for `SEN6`: `_HOT = 70 °C`, `_CRT = 75 °C`).
- **Evidence already captured:** On 2026-11-24 (`01:18`, while `EC reg 0x32` was `1`), our `22 W` `SEN6` policy ran at **`24.0–25.5 t/s` steady** (`0 s` at `400 MHz`, `0 s` PCIe Gen 1, `SEN6` max `64.05 °C`, `6 °C` below Dell's Windows `_HOT = 70 °C`).
- **Honest risk & safety rules (important for out-of-warranty hardware):**
  - `EC reg 0x32 = 1` is **one-way until a full cold shutdown** (no ACPI method clears it).
  - While `EC reg 0x32 = 1`, **software (`thermald` + an external temperature guard)** is responsible for keeping `SEN6` safely below `68–70 °C`; Linux's `SEN6` critical trip only logs and does not stop workloads.
  - Always run a live `SEN6 >= 68 °C` auto-stop guard during testing and complete a **≥30-minute soak** before ever considering persistent setup.
- **How to test in a future session (if ever desired):**
  1. Trigger `DPST(1)` via a 5-second run of `sudo ./sen6-test-thermald.sh adaptive 60` (`Ctrl-C` once `uuid` switches from `INVALID` to passive UUID).
  2. Edit [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) to a clean single passive trip (`SEN6 >= 59 °C → 22 W` or `24 W`) + `<type>max</type>` safety backstop (`SEN6 >= 66 °C → 15 W`), and run `sudo ./sen6-test-thermald.sh custom 3600`.
  3. Start the `SEN6 >= 68 °C` Strata kill-switch guard and run `TRACE_ROUNDS=22` `balanced`-only soak (~30 min).
  4. **Pass criterion:** `0` brakes, `0 s` PCIe Gen 1, `SEN6 <= 65–66 °C` across all 30 min, steady `>= 24–26 t/s`.
  5. **Undo:** `Ctrl-C` restores `115 W` PL1; **full cold shutdown** clears `EC reg 0x32` back to `0`.

---

## 5. Key Files Index & Public-Repo Hygiene

### Active Scripts & Reports (Committed on `xps15-sen6-research`)
- [2026-11-24_handover_neon.md](file:///home/sum/Downloads/AI-Runtime/2026-11-24_handover_neon.md) — **this file** (start here in any future session).
- [2026-11-23-xps15-sen6-research-result-neon.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-neon.md) — full technical report + Section 9 clean-boot addendum.
- [2026-11-23-xps15-sen6-research-result-opus-5.5.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-opus-5.5.md) — Opus 5.5 independent report & peer review.
- [sen6-test-gpu-cpu-cap.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh) — **recommended on-demand safe preset runner** (defaults: `1200 MHz` GPU, `24 W` CPU, `0` = until `Ctrl-C`, `5501 MHz` VRAM; auto-restores on `Ctrl-C`).
- [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh), [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml), [sen6-install-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh), [sen6-uninstall-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh) — `thermald` test/reference scripts (**not installed**; do not run `sen6-install-thermald.sh` for clean-boot use).
- Clean-boot traces & telemetry from 2026-11-24:
  - `strata-throttle-trace-20261124-{1849,2013,2042,2059,2141}-1-balanced.jsonl`, `strata-throttle-trace-20261124-2117-1-performance.jsonl`
  - `sen6-thermald-custom22w-cleanboot-fail-telemetry.txt`, `sen6-thermald-custom-59c20w-63c17w-telemetry.txt`
  - `sen6-gpu1200-cpu22-telemetry.txt`, `sen6-gpu960-cpu22-telemetry.txt`, `sen6-gpu1200-mem5501-cpu24-telemetry.txt`

### Public Repo Hygiene (NEVER Stage or Push)
- `sen6-diag-turbostat.txt` (contains disk/LUKS UUIDs — redacted copy is `xps15-sen6-research/sen6-diag-turbostat-redacted.txt`)
- `BIOS-Check_1.13.0.txt` (contains hardware Serial Number)
- Raw ACPI dumps (`xps15-sen6-research/.../acpi/`)
- Debug/runtime logs: `sen6-thermald-*.log`, `sen6-gpu-cpu-cap.log`, `sen6-gpu-cpu-cap-telemetry.txt`, `sen6-install-thermald.log`
- Do **not** run `export-to-repo.sh` as-is (it globs root `*.txt`/`*.log` and would publish sensitive files).

### Standing "Do Not Do This" List
- Do **NOT** disable `BD PROCHOT` (`wrmsr 0x1FC` bit 0) — proven 0% effective.
- Do **NOT** patch `SSDT4` `_HOT` via initrd ACPI override — proven 0% effective.
- Do **NOT** write undocumented EC registers or enable Manjaro's stock `thermald.service` (`--adaptive`) by hand.
- Do **NOT** repaste/re-pad VRMs expecting to fix `SEN6` (`SEN9` VRM is healthy at `67–75 °C` vs `94 °C` hot).
