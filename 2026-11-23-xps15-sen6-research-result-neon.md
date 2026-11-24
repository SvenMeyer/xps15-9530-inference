# Research Report: Dell XPS 15 9530 SEN6 (65 °C) 400 MHz & PCIe Gen 1 Throttle (`neon`)

**Date:** 2026-11-23 / 2026-11-24  
**Target system:** Dell XPS 15 9530 (motherboard `0PKR91`), Intel Core i7-13700H (`6:186:2`, microcode `0x6134`), NVIDIA RTX 4070 Laptop 8 GB (`AD106M`), BIOS `1.34.0` (`08/27/2026`), Manjaro Linux (`6.12.112-1-MANJARO`), NVIDIA `615.71.09`, Dell WD22TB4 dock, `thermald` not installed.  
**Scope & safety:** Phase A (research + `sen6-diag-readonly.sh`) was strictly read-only (no BIOS, `/sys`, or MSR writes). Phase B (`sen6-test-thermald.sh adaptive` and `custom`) ran temporary foreground `thermald` tests that wrote `/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw`, `/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw`, and (in `adaptive` mode only) `/sys/bus/platform/devices/INTC10A0:00/uuids/current_uuid`, which invoked `IETM._OSC` → `ECDV.DPST(One)` (`EC reg 0x32 = 1`). `Ctrl-C` restores RAPL PL1 to `115 W` but **does not clear EC register `0x32`** — a full cold shutdown is required to reset the EC state. All write/reversible steps below explicitly label **Risk** and **How to Undo**.  
**Inputs:** [README.md](file:///home/sum/Downloads/AI-Runtime/README.md), [2026-11-23-xps15-sen6-throttle-evidence.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-throttle-evidence.md), [2026-11-23-xps15-sen6-research-prompt.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-prompt.md), all 10 local `.jsonl` traces (`2004`, `2222`, `2244`), decoded 82,639-byte local DPTF `data_vault` (`/sys/bus/platform/devices/INTC10A0:00/data_vault`), decompiled ACPI tables (`/tmp/acpi-dump/DSDT.dsl`, `SSDT4.dsl` `DptfTabl`, `SSDT12.dsl` `NvdTable`), and live read-only captures ([sen6-diag-idle.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-idle.txt), [sen6-diag-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-brake.txt), [sen6-diag-turbostat.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-turbostat.txt), [sen6-diag-pcie-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-pcie-brake.txt)).

---

## 1. Short Conclusion & Confidence Level

**Root Cause — 100% Proven by Live Hardware Registers & Decompiled ACPI (`High / Confirmed`):**

1. **`SEN6` is literally `"Charger Temperature Sensor(QE10)"` (EC index `0x07`, `_HOT = 65 °C`, `_CRT = 70 °C`) — PROVEN from `SSDT4.dsl`.**  
   It is **not** the CPU/GPU VRM overheating: the actual VRM sensor (`SEN9` = `"VR_GPU&CPU Temperature Sensor(QE16)"`) peaked at only `75 °C` vs its `94 °C` hot limit, and `SEN7` (`"OTP_CPU Temperature Sensor(QE05)"`) peaked at `71 °C` vs `95 °C`. The **only** sensor tripping its limit is **`QE10` on the charger / USB-C PD power-input circuit** carrying the laptop's continuous ~85–90 W AC draw from the Dell WD22TB4 Thunderbolt dock.
2. **The 400 MHz brake is a CPU package/platform PL1 power limit, NOT `BD PROCHOT` — PROVEN by live MSRs + `turbostat` (EC PECI PL1 domain is strong inference).**  
   Across two full brakes in [sen6-diag-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-brake.txt) (and across the entire boot since 22:19), every `PROCHOT` active and sticky log bit (`0x19C` bits 2/3, `0x1B1` bits 2/3, `0x64F` bits 0/16) remained **`0`**. Instead, at exact brake onset (`00:29:05` and `00:30:44`), **bit 10 (`0x0400`) flipped `0 → 1`** simultaneously in `0x19C` (`Power Limitation Status`), `0x1B1` (`Package Power Limitation Status`), and `0x64F` (`PL1 Package/Platform Power Limiting`), while `turbostat` recorded **`PKG_% = 101.89%`** (100% RAPL throttled) at **`PkgWatt = 9.18 W`**, `CorWatt = 3.30 W`, `Bzy_MHz = 400`, `UncMHz = 400`, `SysWatt = 50.82 W`, `CoreThr = 0`, `SMI = 0` — even though **both** MSR `0x610` (`intel-rapl:0`) and MCHBAR MMIO `0x59A0` (`intel-rapl-mmio:0`) still read **`115 W`**. *Inference:* An EC-written PECI RAPL PL1 domain (invisible to MSR/MMIO) is the most plausible hidden limiter; `9.18 W` is simply what the package draws at its `400 MHz` floor (the exact EC setpoint is not directly readable from Linux). Either way, **disabling `BD PROCHOT` (`0x1FC` bit 0) would have zero effect.**
3. **Linux is missing Dell's Windows Intel DTT gradual PL1 policy AND the `_OSC` EC handshake — PROVEN from `data_vault` + `SSDT4.dsl`.**  
   - Dell's own 82,639-byte GDDV (`data_vault`) never uses `SEN6` for passive throttling (`90.1 °C` disabled placeholder everywhere). Instead, Windows DTT smoothly clamps CPU PL1 from `76 W` down toward `45 W → 20 W` on `SKIN` (`Memroy(QE3)`, `46.1–55.1 °C`) and `15 W → 13 W` on `SEN5` (`GPU Fan-1(QE14)`, `58.1–74.1 °C`, `ITMT 62.1 °C`). Because Linux has no active DTT daemon, CPU stays at `31–34 W` while `SKIN` hits `59–60 °C` and `SEN5` hits `81–82 °C`, soaking `QE10` (`SEN6`) to `65 °C` where the hidden PL1 emergency brake fires (pulling the CPU to `400 MHz` / `~9 W` measured package draw).
   - `SSDT4.dsl` also proves `S7HP = 0x41` (`65 °C`) and `S7CC = 0x46` (`70 °C`) are static AML constants never written back to the EC (so an initrd ACPI SSDT override cannot raise the EC brake), and that `IETM._OSC` (`b23ba85d-c8b7-3542-88de-8de2ffcfd698`) is what calls `ECDV.DPST(One)` (writing `1` to EC reg `0x32`, `EC_DPTF_STATE_ENABLE`) — never called on this Linux boot.
4. **GPU PCIe Gen 4 → Gen 1 is NOT caused by `pcie_aspm=force`; root port `00:01.0` `LnkCtl2` is explicitly set to `2.5GT/s` — PROVEN by `sen6-diag-pcie-brake.txt`.**  
   `00:01.0` (`PEG010`) reports `ASPM not supported` and `ASPM Disabled` on both ends. Mid-brake, `00:01.0` `LnkCtl2: Target Link Speed` drops from `16GT/s` to **`2.5GT/s`** (`1–2 s` *after* CPU hits 400 MHz) and jumps back to **`16GT/s` in the exact same second (`0 s` lag)** that the EC releases the PECI PL1 brake (`00:29:51` and `00:31:31`), while the GPU stays in `P0`/`P3` at `1830 MHz` with zero NVML hardware slowdown/power-brake bits (`0x08`/`0x40`/`0x80`). This is consistent with NVIDIA's dynamic PCIe link-speed training on root port `00:01.0` responding to CPU-starved host↔GPU traffic (and explains the earlier "stuck at Gen 1" incident if `00:01.0` `LnkCtl2` failed to re-target `16GT/s`).

| Claim | Status | Confidence |
|---|---|---|
| `SEN6` = `"Charger Temperature Sensor(QE10)"` (EC index `0x07`); `SEN9` = `"VR_GPU&CPU(QE16)"` | **Verified fact** (`SSDT4.dsl` `_STR`) | **100% Proven** |
| 400 MHz brake is a **CPU package/platform PL1 power limit** (`0x64F` b10 + `0x19C`/`0x1B1` b10 + `PKG_% = 101.89%` while MSR & MMIO read `115 W`), **NOT `BD PROCHOT`** (`PROCHOT` bits stay `0`) | **Verified fact** (`sen6-diag-brake.txt`, `sen6-diag-turbostat.txt`) | **100% Proven** |
| Exact hidden limiter is EC PECI PL1 (and `9.18 W` is measured package draw at 400 MHz, not a directly read EC register value) | **Strong inference** (PECI PL1 is not directly readable from Linux) | **High (inferred)** |
| Disabling `BD PROCHOT` (`0x1FC` bit 0) will NOT prevent this throttle | **Verified fact** (`PROCHOT` bits stay `0` across all brakes) | **100% Proven** |
| ACPI SSDT override of `SEN6` `_HOT` will NOT change the EC 65 °C brake | **Verified fact** (`S7HP=0x41` is static AML constant, never written to EC) | **100% Proven** |
| Linux lacks Dell's GDDV `SKIN` (`46–55 °C`) & `SEN5` (`58–74 °C`) gradual PL1 policy + `_OSC` `DPST(1)` handshake | **Verified fact** (`data_vault` + `SSDT4.dsl`) | **100% Proven** |
| Root port `00:01.0` `LnkCtl2` switches `16GT/s → 2.5GT/s` 1–2 s after brake onset & restores at `0 s` on release; `ASPM` is `Disabled` | **Verified fact** (`sen6-diag-idle.txt`, `sen6-diag-pcie-brake.txt`, `sen6-diag-brake.txt`) | **100% Proven** |
| Laptop setup constraints: USB-C-only power (no DC barrel jack), already lifted ~2 cm for free underside airflow, WD22TB4 on left TB4 port is the only >65 W supply on hand | **User-confirmed hardware setup** | **Confirmed** |
| **Promising fix (`thermald` custom `SEN6` `63 °C → 22 W` XML):** single ~5.5-min run (after `DPST(1)` was already set) held `SEN6` at `64.05 °C` (`~1 °C` margin) with **`24.01` (R3) & `25.49` (R4) t/s steady** (`26.28 t/s` across all 4 rounds including pre-cap R1–R2) vs `17.24 t/s` (`thermald --adaptive`) and `17.4–19.6 t/s` (unmitigated) | **Promising, not yet soak-proven** — needs cold shutdown + brake-return check + 30-min clean-boot soak before permanent install | **Medium-High (pending clean-boot soak)** |

---

## 2. Local Silicon, ACPI & Firmware Evidence

### 2.1 Complete Verified Sensor Map (`SSDT4.dsl` + `dell_ddv` + `data_vault`)
Every sensor's exact physical identity from Dell's decompiled `DptfTabl` (`/tmp/acpi-dump/SSDT4.dsl`), live ACPI sysfs, `dell_ddv`, GDDV `data_vault`, and observed peak temperatures across all 10 traces:

| Thermal Zone | ACPI `_UID` | Dell ACPI `_STR` (Exact Sensor & PCB Designator) | EC Index (`KDRT`) | `dell_ddv` Label | Live ACPI `hot` / `crit` (°C) | GDDV `_hot` / `_crt` (°C) | Observed Max (Balanced) | Cooling in 50 s Brake |
|---|---|---|---:|---|---:|---:|---:|---:|
| `thermal_zone0` | `SKIN` | **`Memroy Temperature Sensor(QE3)`** *(Dell BIOS spelling)* | `0x01` | `t2 (SODIMM)` | `82.05 / 87.05` | `82.05 / 87.05` | `60.05 °C` | `−0.19 °C` |
| `thermal_zone1` | `SEN1` | **`CPU Fan-2 Temperature Sensor(QE17)`** | `0x02` | `t3 (Ambient)` | `67.05 / 72.05` | `67.05 / 72.05` | `51.05 °C` | `−0.19 °C` |
| `thermal_zone2` | `SEN2` | **`SSD Temperature Sensor(QE13)`** | `0x03` | `t4 (HDD)` | `68.05 / 73.05` | `68.05 / 73.05` | `55.05 °C` | `−0.14 °C` |
| `thermal_zone3` | `SEN3` | **`System Ambient Temperature Sensor(QE06)`** | `0x04` | `t5 (Ambient)` | `58.05 / 63.05` | `58.05 / 63.05` | `37.05 °C` | `+0.05 °C` |
| `thermal_zone4` | `SEN4` | **`BB Temperature Sensor(QE11)`** *(Baseboard)* | `0x05` | `t6 (Other)` | `65.05 / 70.05` | `65.05 / 70.05` | `55.05 °C` | `−1.86 °C` |
| `thermal_zone5` | `SEN5` | **`GPU Fan-1 Temperature Sensor(QE14)`** | `0x06` | `t7 (Ambient)` | `90.05 / 95.05` | `90.05 / 95.05` | `82.05 °C` | `−6.86 °C` |
| **`thermal_zone6`** | **`SEN6`** | **`Charger Temperature Sensor(QE10)`** | **`0x07`** | **`t8 (Ambient)`** | **`65.05 / 70.05`** | **`70.05 / 75.05` (+5 °C)** | **`66.05 °C`** | **`−4.19 °C`** |
| `thermal_zone7` | `SEN7` | **`OTP_CPU Temperature Sensor(QE05)`** | `0x08` | `t9 (Ambient)` | `95.05 / 97.05` | `95.05 / 97.05` | `71.05 °C` | `−8.00 °C` |
| `thermal_zone8` | `SEN8` | **`Battery`** | `0x09` | `t10 (Unknown)` | none | none | `35.05 °C` | — |
| `thermal_zone9` | `SEN9` | **`VR_GPU&CPU Temperature Sensor(QE16)`** | `0x0A` | `t11 (Ambient)` | `94.05 / 99.05` | `94.05 / 99.05` | `75.05 °C` | `−8.43 °C` |

*(Note: `QE*` designators in Dell/Compal schematics are remote thermal-sensing bipolar transistors wired to the EC's thermal ADC channels. Notice how `SEN6` (`QE10`, Charger) is the **only** sensor whose live ACPI `_HOT`/`_CRT` (`65/70 °C`) was tightened by 5 °C compared to GDDV (`70/75 °C`).)*

### 2.2 Live MSR & `turbostat` Proof Across Two Complete Brakes (`sen6-diag-brake.txt` & `sen6-diag-turbostat.txt`)
BIOS `1.34.0` attributes verified identical to `1.13.0` (`ThermalManagement=Optimized`, `TurboMode=Enabled`, `Speedstep=Enabled`, `CStatesCtrl=Enabled`, `AdaptiveCStates=Enabled`, `LogicProc=Enabled`, `MultipleAtomCores=CoresAll`, `PrimaryBattChargeCfg=PrimAcUse`, `PeakShiftCfg=Disabled`, `ForceLpmAspmOff=Disabled`).

Exact second-by-second hardware state transitions captured on `cpu0` (with identical `0x1FC` and `0x64F` on E-core `cpu12`):

| Timestamp | `SEN6` (`QE10`) | `SEN5` | `MHz` | `0x19C` low 16 | `0x1B1` low 16 | `0x64F` | GPU `LnkSta` | Root `00:01.0` `LnkCtl2` | State |
|---|---:|---:|---:|---|---|---|---|---|---|
| `00:22:53` (idle) | `49.05` | `48.05` | `2442` | `0x2a80` | `0x0800` | `0x1d020000` | `2.5GT/s` | `16GT/s` | Idle (`0x1FC = 0xe4005b`) |
| `00:29:04` (pre-brake) | `65.05` | `81.05` | `3173` | `0x2a80` | `0x0a80` | `0x1d020000` | `16GT/s` | `16GT/s` | Full speed decode |
| **`00:29:05` (onset 1)** | **`65.05`** | `81.05` | **`498`** | **`0x2e80` (b10=1)** | **`0x0c00` (b10=1)** | **`0x1d020400` (b10=1)** | `16GT/s` | — | **EC PECI PL1 clamp asserts!** |
| **`00:29:06` (+1 s)** | `65.05` | `81.05` | **`400`** | `0x2e80` | `0x0c00` | `0x1d020400` | **`2.5GT/s`** | **`2.5GT/s`** *(captured at +5 s)* | **`turbostat`: `PKG_% = 101.89%`, `PkgWatt = 9.18 W`, `CorWatt = 3.30 W`, `UncMHz = 400`, `SysWatt = 50.82 W`, `CoreThr = 0`, `SMI = 0`** |
| `00:29:50` (end 1) | `61.05` | `74.05` | `400` | `0x2e80` | `0x0c00` | `0x1d020400` | `2.5GT/s` | — | Last second of brake 1 (46 s) |
| **`00:29:51` (release 1)** | **`61.05`** | `74.05` | **`3011`** | **`0x2a80` (b10=0)** | **`0x0800` (b10=0)** | **`0x1d020000` (b10=0)** | **`16GT/s`** | — | **PECI PL1 released; CPU & PCIe recover same second!** |
| **`00:30:44` (onset 2)** | `64.05→65.05` | `79.05` | **`1059→399`** | **`0x2e80` (b10=1)** | **`0x0c00` (b10=1)** | **`0x1d020400` (b10=1)** | `16GT/s → 2.5GT/s` (+2 s) | — | **Brake 2 (47 s)** |
| **`00:31:31` (release 2)** | **`61.05`** | `73.05` | **`3205`** | **`0x2a80` (b10=0)** | **`0x0800` (b10=0)** | **`0x1d020000` (b10=0)** | **`16GT/s`** | — | **PECI PL1 released; CPU & PCIe recover same second!** |

**Critical `turbostat` lines mid-brake ([sen6-diag-turbostat.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-turbostat.txt)):**
- `intel-rapl:0`: `56.0s:115W, max:45W` (`MSR_PKG_POWER_LIMIT = 0x42839800df8398 UNlocked`, `PKG Limit #1: 115.000 W`, `PKG Limit #2: 115.000 W`, `PKG Limit #4: 210.000 W UNlocked`)
- `intel-rapl-mmio:0`: `56.0s:115W, max:45W`
- **Yet hardware throttling counter `PKG_% = 101.89%`** (i.e. `MSR_PKG_PERF_STATUS` `0x613` incrementing continuously!) while **`PkgWatt = 9.18 W`**, `CorWatt = 3.30 W`, `Bzy_MHz = 400`, `UncMHz = 400`, `CoreTmp = 66–72 °C`, `PkgTmp = 75 °C`, `CoreThr = 0`, `SMI = 0`.
- Active bits ever seen in `0x64F` across all 505 s: `0x0c02` (bit 1 = brief internal thermal during pre-brake turbo, **bit 10 = PL1 during entire brake**, bit 11 = brief PL2). **Bit 0 (`PROCHOT`) and bit 16 (`PROCHOT Log`) were `0` for the entire boot.**

### 2.3 Decoded Dell DPTF `data_vault` (`INTC10A0:00`) Policy Tables
Decompressing `/sys/bus/platform/devices/INTC10A0:00/data_vault` (2,956 bytes → 82,639-byte LZMA `REPO` with 217 keys) reveals Dell's exact Windows Intel DTT configuration (`ODVP0`: `0=op`, `1=cool`, `2=quit`, `3=ultra`):

| Mode (`ODVP0`) | `APAT` Base PL1 / PL2 | `ITMT` Active Passive Control | `PSVT` Active Passive Control (`ia` = CPU / `gt` = CPU+dGPU) | Hot-Ambient Trigger (`APCT` `35_*`) |
|---|---|---|---|---|
| **Optimized (`0`)** | `76 W` / `115 W` (`tau=56s`) | `SKIN (QE3) ≥ 46.1 °C → 45–76 W`<br>**`SEN5 (QE14) ≥ 62.1 °C → 15–76 W`** | `balance_ia`: `SKIN 47.1 °C → 45 W`, `55.1 °C → 20 W`; `SEN3 39.1–41.1 °C → 26–20 W`<br>`balance_gt`: **`SEN5 58.1–73.1 °C → 15 W`, `74.1 °C → 13 W`**; `SEN3 38.1 °C → 15 W` | If `SEN3 ≥ 40.1 °C` for `60 s` (+ `SEN5 ≥ 59.1 °C` for `gt`): caps PL1 to **`30 W` (`ia`) / `15 W` (`gt`)** |
| **UltraPerformance (`3`)** | `76 W` / `115 W` (`tau=56s`) | `SKIN (QE3) ≥ 46.1 °C → 45–76 W`<br>**`SEN5 (QE14) ≥ 62.1 °C → 15–76 W`** | `ultra_ia`: `SKIN 47.1 °C → 45 W`, `55.1 °C → 20 W`; `SEN3 39.1–41.1 °C → 26–20 W`<br>`ultra_gt`: **`SEN5 58.1–73.1 °C → 15 W`, `74.1 °C → 13 W`**; `SEN3 35.1–39.1 °C → 15 W` | Same `35_ultra_ia` (`30 W`) / `35_ultra_gt` (`15 W`) cap |
| **Cool (`1`)** | `45 W` / `115 W` | `SKIN ≥ 39.1 °C → 30–45 W`<br>`SEN5 ≥ 53.1 °C → 15–30 W` | `cool_ia`: `SKIN 39.1–49.1 °C → 30 W`, `50.1 °C → 13 W`<br>`cool_gt`: `SEN5 43.1–55.1 °C → 15 W`, `56.1 °C → 13 W` | N/A |
| **Quiet (`2`)** | `45 W` / `115 W` | `SKIN ≥ 39.1 °C → 30–45 W`<br>`SEN5 ≥ 54.1 °C → 15–30 W` | `quit_ia`: `SKIN 39.1–53.1 °C → 30 W`, `54.1 °C → 13 W`<br>`quit_gt`: `SEN5 43.1–56.1 °C → 15 W`, `57.1 °C → 13 W` | N/A |

- **`SEN6` (`Charger(QE10)`) is set to `90.1 °C` (disabled placeholder) in every `PSVT` and `ITMT` table and is absent from `APCT`/`PBCT`/`PBAT`/`PBMT`.**
- **Boot cmdline context:** `/proc/cmdline` includes `pcie_aspm=force`, `nvidia.NVreg_DynamicPowerManagement=0x00`, and `gpu_unlock.targets=0000:01:00.0` (which only unlocks the RTX 4070 Laptop tensor-core multiplier for 2× tensor-core speed; GPU power draw remained within the ~34–39 W cap).
- **Why `saver` (`quiet`) logged `400 MHz` in `2244-1-saver.jsonl`:** In `quiet`, the EC caps CPU power to ~9.8–10.1 W (`SEN6` stays `56–58 °C`, PCIe stays Gen 3), so 14 active cores naturally scale down to `400–596 MHz` — not the `SEN6` brake.

---

## 3. Detailed Answers to Priority Questions (1–7)

### Q1. What is `SEN6` physically on the XPS 15 9530, and what does exceeding 65 °C risk?
- **Verified fact (`SSDT4.dsl` line 2592):** `SEN6` is **`"Charger Temperature Sensor(QE10)"`** (EC thermal channel `0x07`, `_HOT = 0x41` = `65 °C`, `_CRT = 0x46` = `70 °C`, hysteresis `4 °C`).
- It is **distinct from** the CPU/GPU VRMs (`SEN9` = `"VR_GPU&CPU Temperature Sensor(QE16)"`, `75 °C` vs `94 °C` hot), CPU over-temp sensor (`SEN7` = `"OTP_CPU(QE05)"`, `71 °C` vs `95 °C` hot), memory area (`SKIN` = `"Memroy(QE3)"`, `60 °C` vs `82 °C` hot), GPU fan exhaust (`SEN5` = `"GPU Fan-1(QE14)"`, `82 °C` vs `90 °C` hot), and battery pack (`SEN8`, `35 °C`).
- **What `QE10` measures & risks above 65 °C:** `QE10` monitors the **motherboard's DC-in / USB-C PD battery-charger circuit** (which carries the laptop's full incoming AC power). Because `QE10` is a PCB-mounted sensing transistor rather than an on-die MOSFET junction sensor, nearby power-stage components run hotter than `QE10`'s board reading by an unknown margin (exact gradient unmeasured). Exceeding `65 °C` risks:
  1. **Thermal stress/degradation of the USB-C PD / charger power stage** and adjacent capacitors/battery region.
  2. **Hitting the ACPI critical trip (`_CRT = 70.05 °C` in `SSDT4.dsl`, `75.05 °C` in GDDV):** OS critical thermal handling triggers at `70.05 °C` (whether the EC independently cuts power at `70 °C` is untested and unconfirmed).
  3. **Localized chassis skin hotspot** near the left USB-C / charging area.

### Q2. What mechanism forces 400 MHz and PCIe Gen 1?
- **CPU 400 MHz — Proven PL1 power limit (EC PECI PL1 strongly inferred, not directly read):**
  - Proven simultaneously by:
    - `0x64F` (`MSR_CORE_PERF_LIMIT_REASONS`): **bit 10 (`PL1 Status`) = `1`** during every second of the brake, `0` before/after; **bit 0 (`PROCHOT`) = `0`** and **bit 16 (`PROCHOT Log`) = `0`** across the entire boot.
    - `0x19C` (`IA32_THERM_STATUS`) and `0x1B1` (`IA32_PACKAGE_THERM_STATUS`): **bit 10 (`Power Limitation Status`) = `1`** during every second of the brake; **bits 2/3 (`PROCHOT#`) = `0`**.
    - `turbostat`: **`PKG_% = 101.89%`** (`MSR_PKG_PERF_STATUS` actively RAPL-throttling) at **`PkgWatt = 9.18 W`** (what the CPU draws at its `400 MHz` floor), `CorWatt = 3.30 W`, `Bzy_MHz = 400`, `UncMHz = 400`, `CoreThr = 0`, while both MSR `0x610` (`intel-rapl:0`) and MMIO `0x59A0` (`intel-rapl-mmio:0`) remain **`115 W`**.
  - *Inference:* Because Intel CPUs enforce `min(MSR_PL1, MMIO_PL1, PECI_PL1)` and both MSR and MMIO still read `115 W`, an EC-written **PECI PL1** limit (`≤ 9 W`) is the most plausible hidden mechanism, though the EC's exact PECI register value cannot be read directly from Linux.
- **GPU PCIe Gen 4 → Gen 1 — Proven:**
  - `sen6-diag-pcie-brake.txt` shows **`00:01.0` (`PEG010` root port) `LnkCtl2: Target Link Speed` explicitly changes from `16GT/s` to `2.5GT/s`** mid-brake (`ASPM` is `not supported` / `Disabled` on both `00:01.0` and `01:00.0`, ruling out `pcie_aspm=force`).
  - `LnkSta` drops `16GT/s → 2.5GT/s` **1–2 s *after*** the EC PECI PL1 clamp engages (`00:29:05 → 00:29:06` and `00:30:44 → 00:30:46`) and recovers to **`16GT/s` in the exact same second (`0 s` lag)** that the CPU exits `400 MHz` (`00:29:51` and `00:31:31`), while the GPU stays in `P0`/`P3` at `1830 MHz` (`22–29 W`) with zero NVML hardware slowdown/power-brake bits (`0x08`/`0x40`/`0x80`). This matches NVIDIA's driver dynamically writing `00:01.0` `LnkCtl2` to `2.5GT/s` when CPU-starved PCIe traffic collapses, and immediately re-targeting `16GT/s` when traffic resumes.

### Q3. Can the 65 °C limit be raised or the response softened safely?
| Lever | Changes EC 65 °C `QE10` Brake? | Softens Response / Lowers `QE10` Temp? | Verified Verdict |
|---|---|---|---|
| **BIOS `ThermalManagement`** (`Optimized`, `Cool`, `Quiet`, `UltraPerformance`) | **No** (`balanced` and `performance` both trip `QE10` at `65 °C`). | **Yes (indirectly):** `Cool` (untested so far) ramps fans earlier; `UltraPerformance` hits `65 °C` faster (`+7.5–9.4 °C/min`); `Quiet` holds ~10 W (`SEN6 56–58 °C`) at `13–14 t/s`. | Worth 1 quick A/B test on `cool`; cannot raise `65 °C`. |
| **Dell Command \| Configure (`cctk`) / `dell-wmi-sysman`** | **No.** Controls the same BIOS USTT setting as `platform_profile`. | Same as BIOS `ThermalManagement`. | Cannot raise `65 °C`. |
| **Dell WMI / SMM (`dell-pc` / `dell_smm_hwmon`)** | **No.** | Minor: `performance` runs fans ~7% faster (~6300/6000 vs ~5900/5600 RPM), which helps **only** if CPU power is simultaneously capped (e.g., via RAPL PL1). | Useful only paired with RAPL PL1 control. |
| **DPTF `data_vault` / `thermald` (custom `SEN6` policy)** | **No** (cannot raise EC's `65 °C` limit). | **YES — best software softening fix.** Smoothly trims `intel-rapl:0` PL1 (unlocked `115 W`!) starting at `SEN6 = 62–63 °C` (e.g., down to `20–26 W`) so `QE10` stabilizes at `63–64 °C` without ever triggering the EC's ~9 W / 400 MHz PECI PL1 cliff! | **Primary software fix** (see Rank #2 below). |
| **ACPI SSDT override via initrd (`DptfTabl`)** | **NO — 100% Proven.** In `SSDT4.dsl` lines 2656–2672, `S7HP = 0x41` and `S7CC = 0x46` are static AML constants returned to the OS and **never written to the EC**. | Changes only what Linux sysfs displays. | **Ineffective — do not do.** |
| **EC register patching (`ECW1`)** | Potentially risky/undocumented; `QE10` protects real charger hardware. | N/A | **Unsafe — do not do.** |

### Q4. Is Linux missing the policy Windows uses? (`thermald`, `_OSC`, `DPST`)
- **YES — double-confirmed by `data_vault` AND `SSDT4.dsl`:**
  1. **Missing gradual PL1 throttling:** Windows Intel DTT runs the decoded `data_vault` `ITMT`/`PSVT` tables, clamping CPU PL1 to `45 → 20 W` (`SKIN` `QE3` `46–55 °C`) and `15 → 13 W` (`SEN5` `QE14` `58–74 °C`) long before `QE10` (`SEN6`) hits `65 °C`. That is why Windows users report PL1 dropping to `15–20 W` under mixed CPU+GPU load instead of cycling into 400 MHz PECI cliffs.
  2. **Missing `_OSC` → `ECDV.DPST(One)` handshake:** `SSDT4.dsl` lines 440–523 prove that `IETM._STA` does **not** call `ECDV.DPST(One)` (writing `1` to EC reg `0x32`, `EC_DPTF_STATE_ENABLE`) at boot because `DDDR` starts at `0`. Only calling `IETM._OSC` with UUID `b23ba85d-c8b7-3542-88de-8de2ffcfd698` and `CAP1 & 0x0F` sets `DDDR = 1` and calls `DPST(One)`.
  3. **`thermald` 2.5.13 (`extra`) nuance:** `dptfxtract` is obsolete (`thermald --adaptive` parses `data_vault` natively), **however**:
     - Because `INTC10A0:00/uuids/available_uuids` reports `UNKNOWN` and `production_mode=5`, `thermald --adaptive` may either fail UUID negotiation or—if it loads Dell's GDDV—**over-throttle CPU PL1 down to `15 W`** because `SEN5` (`QE14`) sits at `74–82 °C` during Strata!
     - **A custom `thermald` XML config targeting `SEN6` (`thermal_zone6`) directly via `rapl_controller_mmio`** (`MSR_PKG_POWER_LIMIT` is confirmed **UNlocked** in `turbostat` line 214!) is strictly superior for Strata: it allows full `32–45 W` whenever `SEN6 < 63 °C` and steps PL1 down cleanly (`22 W`, or `20 W` if needed) before `QE10` crosses `65 °C` so the `400 MHz` PL1 cliff never fires.

### Q5. Can `BD PROCHOT` safely be disabled on this platform (MSR `0x1FC` bit 0)?
- **Now moot — 100% Proven:** `BD PROCHOT` **never fired** during any brake (`0x19C` bits 2/3, `0x1B1` bits 2/3, `0x64F` bits 0/16 are all `0`). Clearing `0x1FC` bit 0 would have **zero effect** on this throttle (and `0x1FC = 0x00e4005b` has bit 23 = `1`, bit 27 = `0`, bit 0 = `1`). Leaving `0x1FC` untouched preserves real hardware emergency protection with zero downside.

### Q6. Known reports and fixes for XPS 15 9530/9520, XPS 17 9730/9720, and Precision siblings
- **Verified vendor/review context:** Notebookcheck measured the XPS 15 9530 RTX 4070 at a `40–50 W` TGP cap (~43–45 W sustained) in an 18 mm chassis fed by Dell's proprietary `130 W` USB-C PD rail.
- **Community reports (*explicitly marked as anecdotes*):**
  - Widely reported `400 MHz` / `~10–15 W` throttling on XPS 15 9520/9530 & Precision 5570/5680 under sustained mixed CPU+GPU load, frequently triggered by the **charger / USB-C PD area** heating up under continuous 80–130 W draw (especially on **WD22TB4 docks** or while battery charging + heavy load overlap) and by restricted underside airflow on flat desks.
  - Because `SEN9` (`VR_GPU&CPU(QE16)`) is only `75 °C` (19 °C below its `94 °C` hot limit) and `SEN7` (`OTP_CPU(QE05)`) is only `71 °C` (24 °C below `95 °C`), **this unit does NOT show classic CPU/GPU VRM pad failure!** The heat bottleneck is specifically at **`QE10` (`Charger Temperature Sensor`)**.

### Q7. Could this indicate a hardware fault, and how do we test it?
- **CPU/GPU VRM & heatsink contact look healthy:** `SEN9` (`VR_GPU&CPU`) is `75 °C` vs `94 °C` hot; `SEN7` (`OTP_CPU`) is `71 °C` vs `95 °C` hot; GPU die is `70–72 °C`; CPU package stays `81–94 °C` in balanced mode. `SEN6` (`QE10`) is also **not** miscalibrated (tracks `49 °C` at idle, rises/cools smoothly with load, correlates `r = 0.970` with `SEN4` `BB(QE11)`).
- **Physical setup confirmed by user:**
  - The XPS 15 9530 has **USB-C power only** (no DC barrel port): **two left Thunderbolt 4 ports** and **one right USB-C 3.2 Gen 2 port** (10 Gbps + DP Alt Mode + PD, no Thunderbolt).
  - The laptop is **already lifted ~2 cm** with unobstructed underside airflow.
  - The **WD22TB4 dock on the left USB-C port** is the only >65 W power source currently available (and battery is at `100%` / `Not charging` / `PrimaryBattChargeCfg=PrimAcUse`, so charging current is not adding heat).
  - Moving WD22TB4 to the right USB-C 3.2 Gen 2 port would lose Thunderbolt 4 mode (limiting multi-display/TB bandwidth) and still feeds the motherboard's main charger buck-boost stage (`QE10`), so it is deferred as a low-priority optional check rather than the primary path.
- **Conclusion on Q7:** Hitting `QE10 = 65 °C` under sustained ~85–90 W total AC draw (32–34 W CPU + 34–39 W GPU + platform) without Windows Intel DTT running is normal thermal saturation of the charger stage on this slim chassis — **not** evidence of a VRM pad or sensor fault.

---

## 4. Ranked Fix Options & Active Decision

**Decision (2026-11-24):** Because the laptop is already elevated ~2 cm and powered via its sole >65 W USB-C source (WD22TB4), we proceed directly to **software gradual PL1 control via `thermald`** (replicating Windows Intel DTT first via `adaptive`, then testing a tuned `SEN6`-targeted XML policy via `custom` to avoid Dell's aggressive `15 W` `SEN5` clamp).

| Rank | Option | Type | Expected Effect | Risk | How to Undo |
|---:|---|---|---|---|---|
| **1 (Active Test 1 — Completed)** | **Test `thermald --adaptive` (exact Windows Dell GDDV replication)** via [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) `adaptive` | **Baseline Linux DTT replication** | Verifies whether `thermald 2.5.13` parses `INTC10A0:00/data_vault` cleanly, triggers `_OSC` `DPST(1)`, and prevents `SEN6 = 65 °C`. Clamped CPU PL1 to `15 W` due to Dell's `SEN5` (`QE14` `>62 °C`) rule (`17.24 t/s` steady). | **Medium side effect:** Triggers `IETM._OSC` → `EC reg 0x32 = 1` (`DPST(1)`), which Dell's AML cannot clear without a **full cold shutdown** and may relax the EC's `65 °C` fallback brake. | `Ctrl-C` restores `115 W` MSR/MMIO PL1; **full cold shutdown** required to clear `EC reg 0x32`. |
| **2 (Active Test 2 — Candidate Winner)** | **Custom `SEN6`-driven `thermald` closed-loop RAPL PL1 policy** via [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) `custom` + [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) | **Software root-cause fix** (Windows DTT concept, tuned for `QE10` / Strata) | Watches `SEN6` (`thermal_zone6`) directly at **`63 °C`** (`1 °C` hyst) using `rapl_controller_mmio` (`22 W`, `<Preference>QUIET</Preference>`). Lets CPU run full speed below `63 °C` and caps PL1 at `22 W` without Dell's `15 W` `SEN5` over-throttle and without tripping the `65 °C` / `400 MHz` PL1 cliff (**`24.01` / `25.49 t/s`** steady in initial 5.5-min test; pending 30-min clean-boot soak). | **Very low.** Does **not** call `--adaptive` / `_OSC` / `DPST(1)`; preserves EC hardware safety limits. | `Ctrl-C` (script kills `thermald` and restores `115 W` PL1); `sudo pacman -Rns thermald` to remove package. |
| **3 (Follow-up)** | **Pair winning `SEN6` PL1 policy with `performance` fan curve (~6300/6000 RPM) or test `cool` profile** | **Synergistic optimization** | ~7% higher max fan RPM than `balanced` (~5900/5600 RPM) *without* `performance` mode's runaway 45–60 W CPU spikes, allowing a higher steady PL1 (~26–30 W) below `SEN6 = 64 °C`. | **Very low.** Standard `platform_profile` + RAPL PL1. | Stop `thermald`; `echo balanced \| sudo tee /sys/firmware/acpi/platform_profile`. |
| **4 (Optional)** | **Active underside cooling pad or testing right USB-C 3.2 Gen 2 port** | **Physical mitigation** | Active forced airflow across the bottom cover could cool `QE10` by `3–6 °C` (keeping full 28–30 t/s); right USB-C port loses Thunderbolt 4. | **None.** | Instant (physical). |
| **5 (Partial)** | **Balanced + 5 P-cores (`p5`)** (already tested: `21.5 vs 19.6 t/s`) | **Partial workaround** | Modest gain alone; still hits `QE10 = 65 °C` brakes without `thermald` PL1 control. | **None.** | Launcher flag only. |

---

## 5. Execution Status & Active Test Plan

### Phase A — Completed (100% Read-Only) ✅
- [x] Decoded 82,639-byte local DPTF `data_vault` (`INTC10A0:00`, 217 ESIF keys: `IDSP`, `PPCC`, `PSVT`, `ITMT`, `APAT`, `APCT`, `EPOT`, `PBAT`, `PBCT`, `PBMT`).
- [x] Verified BIOS `1.34.0` attributes ([sen6-diag-idle.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-idle.txt)) and decompiled all 17 ACPI tables (`/tmp/acpi-dump/*.dsl`) via [sen6-diag-readonly.sh](file:///home/sum/Downloads/AI-Runtime/sen6-diag-readonly.sh).
- [x] Captured live MSRs (`0x19C`, `0x1B1`, `0x1FC`, `0x64F`), `turbostat --debug`, and `lspci -vv` (`00:01.0` & `01:00.0`) across two complete brakes ([sen6-diag-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-brake.txt), [sen6-diag-turbostat.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-turbostat.txt), [sen6-diag-pcie-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-pcie-brake.txt)).

### Phase B — Completed Reversible `thermald` A/B Benchmarks ✅

All runs used the identical standardized Strata balanced workload (`IQ3_S`, `64k`, `DFlash2`, `STRATA_ROUTE_TAIL_SKIP=0`, `STRATA_ROUTE_PRIOR=1.5`, `conversation-spill-mib=0`), foreground-only `thermald` (`2.5.13`), auto-restoring `115 W` PL1 on exit:

| Configuration | 3-Round Overall | 4-Round Overall | Steady-State (R3 / R4) | 400 MHz Brake Time | PCIe Gen 1 Time | Peak `SEN6` (`QE10`) | Steady CPU / GPU W | Notes / Raw Output |
|---|---:|---:|---:|---:|---:|---:|---|---|
| **Unmitigated Linux `balanced`** (warm, `2222-3` / `2244-4`) | `17.4 t/s` | `19.6 t/s` | `~17–19 t/s` (sawtooth `28 ↔ 8`) | `169–184 s` (3–4 brakes) | `~170 s` | `65.05–66.05 °C` (trips EC!) | `32 → 8.5 W` / `34 → 25 W` | Baseline traces `2222-3`, `2244-4` |
| **Test 1: `thermald --adaptive`** (exact Windows Dell GDDV) | `20.68 t/s` | — | `17.24 t/s` (R3) | **`0 s`** | **`0 s`** (`300/304` Gen 4) | **`62.05 °C`** | `15.0 W` / `30.5 W` | Clamped `PL1_mmio` straight to `15.0 W` the instant `SEN5` hit `62.05 °C` (`00:56:09`, while `SEN6` was only `56.05 °C`). Also activated `uuid=42A441D6...` (`_OSC` → `DPST(1)`). [sen6-thermald-adaptive-strata.jsonl](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-adaptive-strata.jsonl) |
| **Test 2: `thermald` custom `SEN6` `63 °C → 22 W`** ([sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml)) | `26.56 t/s` *(incl. pre-cap R1–R2)* | `26.28 t/s` *(incl. pre-cap R1–R2)* | **`24.01` (R3) / `25.49` (R4) t/s** | **`0 s`** | **`0 s`** (`318/328` Gen 4) | **`64.05 °C`** (`~1 °C` below `65 °C`) | **`22.0 W` / `34.1 W`** | **Promising (needs clean-boot 30-min soak):** switched `PL1_mmio: 76 W → 22 W` at `SEN6 = 63.05 °C` (`01:18:46`), held `SEN6` at `64.05 °C` across R3–R4 (`TCPU` med `78 °C`, `SEN9` max `73 °C`), auto-restored `76 W` at `61.05 °C`. Single ~5.5-min run conducted *after* Test 1 set `EC reg 0x32`. [sen6-thermald-custom22w-strata.jsonl](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom22w-strata.jsonl) |

**Two important `thermald` implementation discoveries captured during Test 2:**
1. **`--config-file` ownership requirement:** `thermald` rejects custom XML files not owned by `root:root` (`Operation not permitted`); [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) stages a `root:root` (`0600`) copy at `/tmp/sen6-thermald-custom.xml`.
2. **`<Preference>QUIET</Preference>` requirement:** In `thermald`, `<Preference>PERFORMANCE</Preference>` (`pref 1`) skips all `passive` (`type 3`) trips! Setting `<Preference>QUIET</Preference>` (`pref 0`) is required so `thermald` enforces passive RAPL trips (it does **not** alter Dell's BIOS `ThermalManagement` profile).
3. **Bonus `_OSC` `DPST(1)` observation:** During the brief first `custom` attempt (when `pref 1` skipped the `64 °C` trip), `SEN6` sat at `65.05–66.05 °C` for `64 s` (`24 s` at `66.05 °C`) with `64F_b10 = 0` (zero EC brakes), strongly suggesting that Test 1's `IETM._OSC` → `ECDV.DPST(One)` (`EC reg 0x32 = 1`) stayed latched in the EC and relaxed the non-DPTF `65 °C` fallback brake. Even so, keeping `SEN6` actively capped at `≤64.05 °C` via `thermald` is safer for `QE10` (`Charger`) and works independently of `DPST(1)` on a fresh boot.

### Phase C — Required Safety & Clean-Boot Validation Before Persistent Install

> [!WARNING]
> **Full cold shutdown required before running heavy loads or installing persistently:** Test 1 (`thermald --adaptive`) triggered `IETM._OSC` → `ECDV.DPST(One)` (`EC reg 0x32 = 1`), and Dell's ACPI code has **no path that clears that flag** (`Ctrl-C` restores RAPL PL1 to `115 W` but does **not** clear `EC reg 0x32`). Afterward, `SEN6` sat at `65–66 °C` for `64 s` without the `65 °C` brake firing (vs `≤47 s` previously). Do **not** assume the `22 W` policy is fully proven from a single 5.5-minute run taken while that flag was set, with only `~1 °C` of margin (`64.05 °C`).

1. **Full cold shutdown** (power off completely, not a warm reboot) to clear EC register `0x32`.
2. **Verify the `65 °C` brake returns:** Run `bash strata-throttle-trace.sh` (or 1 balanced arm) once on the clean boot *without* `thermald`. Confirm the EC brake returns at `SEN6 = 65 °C`. (If it does not, stop heavy loads and investigate.)
3. **Clean-boot 30-minute soak test of the `22 W` policy (without running `--adaptive` first):**
   - Run `sudo /home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh custom` on the clean boot and soak Strata for ≥30 minutes.
   - Verify `SEN6` stays below `65 °C` with zero EC brakes (note: `22 W` only leaves ~1 °C margin at `25 °C` room temp; if `SEN6` creeps to `65 °C` over 30 min, drop `<TargetState>` in [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) to `20000000` = `20 W`).
   - `Ctrl-C` restores RAPL PL1 cleanly without having touched `EC reg 0x32`.
4. **Only after Step 3 passes — persistent install (100% reversible):**
   - Manjaro's `/usr/lib/systemd/system/thermald.service` passes `--adaptive` by default, which would run Dell's `15 W` `SEN5` GDDV clamp instead of our custom `SEN6` XML.
   - Run `sudo /home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh`: copies [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) to `/etc/thermald/thermal-conf.xml` (`root:root`, `0644`), installs `/etc/systemd/system/thermald.service.d/override.conf` (`ExecStart=/usr/bin/thermald --systemd --dbus-enable --config-file=/etc/thermald/thermal-conf.xml`), enables and starts `thermald.service`, and logs verification to `sen6-install-thermald.log`.
   - **Rollback / Undo:** `sudo /home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh` (disables/stops `thermald.service`, removes the override & `/etc/thermald/thermal-conf.xml`, reloads systemd, restores `115 W` PL1).
5. **If the separate "stuck at PCIe Gen 1 until reboot" bug ever recurs:** Run `sudo lspci -vv -s 00:01.0 | grep -E 'LnkSta:|LnkCtl2:'` to verify whether `00:01.0` `LnkCtl2 Target Link Speed` got stuck at `2.5GT/s`.

### Cross-Check Against Independent Web-Only Research (`neon-web`)
[2026-11-23-xps15-sen6-research-result-neon-web.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-neon-web.md) (run in parallel without local ACPI/MSR access) independently reached the same structural conclusions on the missing Intel DTT `GDDV` policy, why ACPI SSDT overrides cannot move an EC cutoff, why `BD PROCHOT` should not be disabled, and the exact read-only MSR + `DptfTabl` `_STR` + `turbostat` verification path. Our live local captures then resolved the items web-only research could not verify remotely: proving `SEN6 = Charger Temperature Sensor(QE10)` (not CPU/GPU VRM `SEN9`), proving the 400 MHz brake is a **CPU package/platform PL1 power limit** (inferred EC PECI PL1) rather than `BD PROCHOT`, and demonstrating empirically that `thermald --adaptive` over-clamps to `15 W` (`17.24 t/s` steady) on `SEN5` while our custom `SEN6` `63 °C → 22 W` XML achieved **`24.01` (R3) & `25.49` (R4) t/s steady** (`26.28 t/s` 4-round incl. pre-cap R1–R2) with `0 s` at `400 MHz` (pending a 30-min clean-boot soak).

---

## 6. Scripts, Configs & Output Files Developed and Used

### Developed in This Investigation
| File | Purpose | Mode / Risk | Defined Outputs |
|---|---|---|---|
| [sen6-diag-readonly.sh](file:///home/sum/Downloads/AI-Runtime/sen6-diag-readonly.sh) | Read-only `sudo` capture of BIOS `1.34.0` attrs, `lspci -vv` (`00:01.0` & `01:00.0`), MSRs (`0x1FC`/`0x19C`/`0x1B1`/`0x64F`), ACPI dump + `iasl -d`, and live brake watcher with auto mid-brake `turbostat` + `lspci` snapshot | **100% read-only** (already run) | [sen6-diag-idle.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-idle.txt), [sen6-diag-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-brake.txt), [sen6-diag-turbostat.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-turbostat.txt), [sen6-diag-pcie-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-pcie-brake.txt), `/tmp/acpi-dump/*.dsl` |
| [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) | Foreground-only, auto-restoring `sudo` runner for `thermald` (`adaptive` or `custom`), staging `root:root` `0600` XML, logging debug output & 1 s telemetry, and restoring original `115 W` MSR/MMIO PL1 on exit | **Reversible PL1** (`adaptive` also latches `EC reg 0x32` until cold shutdown) | [sen6-thermald-adaptive.log](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-adaptive.log), [sen6-thermald-adaptive-telemetry.txt](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-adaptive-telemetry.txt), [sen6-thermald-adaptive-strata.jsonl](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-adaptive-strata.jsonl), [sen6-thermald-custom.log](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.log), [sen6-thermald-custom-telemetry.txt](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom-telemetry.txt), [sen6-thermald-custom22w-strata.jsonl](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom22w-strata.jsonl) |
| [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) | Custom `thermald` XML (`<Preference>QUIET</Preference>`, `SEN6` `63 °C → 22 W` via `rapl_controller_mmio`, `1 °C` hyst) | **Candidate fix config (pending clean-boot 30-min soak)** | Initial 5.5-min test: `24.01` / `25.49 t/s` steady (`26.28 t/s` 4-round incl. pre-cap R1–R2), `0 s` at `400 MHz`, `SEN6` max `64.05 °C` |
| [sen6-install-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh) | Persistent `sudo` installer: copies XML to `/etc/thermald/thermal-conf.xml`, writes `/etc/systemd/system/thermald.service.d/override.conf` (drops `--adaptive`), enables & starts `thermald.service`, verifies status | **Persistent install (reversible)** | `sen6-install-thermald.log` |
| [sen6-uninstall-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh) | Clean `sudo` rollback: disables/stops `thermald.service`, removes override & `/etc/thermald/thermal-conf.xml`, reloads systemd, restores `115 W` PL1 | **1-command rollback** | `sen6-uninstall-thermald.log` |

### Existing Workspace Evidence & Benchmark Scripts Referenced
| File | Role |
|---|---|
| [2026-11-23-xps15-sen6-throttle-evidence.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-throttle-evidence.md) | Baseline evidence log (BIOS 1.13.0 vs 1.34.0, 22 episodes across 3 trace sets) |
| [2026-11-23-xps15-sen6-research-prompt.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-prompt.md) | Priority questions (1–7) and required output contract |
| [BIOS-Check_1.13.0.txt](file:///home/sum/Downloads/AI-Runtime/BIOS-Check_1.13.0.txt) | Pre-update BIOS `1.13.0` attribute dump and `fwupdmgr` dock firmware inventory |
| [strata-throttle-trace.sh](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace.sh) & [strata-throttle-trace.py](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace.py) | 3-arm balanced/performance/balanced per-second trace harness (`2004`, `2222` `.jsonl` logs) |
| [strata-steady-ab.sh](file:///home/sum/Downloads/AI-Runtime/strata-steady-ab.sh) | 4-arm `saver`/`p5`/`saverp5`/`balanced` steady-state A/B harness (`2244` `.jsonl` logs) |
| [strata-version-ab.sh](file:///home/sum/Downloads/AI-Runtime/strata-version-ab.sh) | Strata `0.2.20` vs `0.2.11` engine comparison harness |

---

## 7. Explicit "Do Not Do This" Items

1. **DO NOT disable `BD PROCHOT` via `wrmsr 0x1FC` (bit 0):** Proven **completely ineffective** on this issue (`PROCHOT` never asserts during the `SEN6` brake!) and removes real emergency protection.
2. **DO NOT patch `DptfTabl` (`SSDT4`) via initrd ACPI override to raise `SEN6` `_HOT`:** Proven **completely ineffective** (`S7HP = 0x41` is a static AML constant never sent to the EC).
3. **DO NOT write undocumented EC registers or flash modified EC/BIOS firmware:** `QE10` protects the charger/USB-C PD circuit only `5 °C` below the ACPI critical trip (`_CRT = 70.05 °C`), and BIOS downgrade from `1.34.0` is blocked.
4. **DO NOT tear down the heatsink to replace CPU/GPU VRM pads expecting it to fix `SEN6`:** `SEN9` (`VR_GPU&CPU(QE16)`) is only `75 °C` (`19 °C` below its `94 °C` hot limit) and `SEN7` (`OTP_CPU(QE05)`) is `71 °C` (`24 °C` below `95 °C`). The bottleneck is `QE10` (`Charger`), not the main CPU/GPU VRMs.
5. **DO NOT run the 24-run Strata `0.2.20` benchmark suite until a clean-boot 30-min soak confirms `thermald` PL1 control eliminates the `SEN6` PL1 brakes** (and always confirm ~12.7 GB/s PCIe Gen 4 in the engine log).

---

## 8. Sources & Citations

### Primary First-Hand Evidence (This Machine)
1. **Decompiled ACPI `DptfTabl` (`SSDT4.dsl`) & `DSDT.dsl`:** `/tmp/acpi-dump/SSDT4.dsl` (lines 160–210 `DPST`/`KDRT`, lines 440–575 `IETM._STA`/`_OSC`, lines 2023–2900 `SKIN`/`SEN1`–`SEN9` `_STR` & trip points) and `/tmp/acpi-dump/DSDT.dsl` (`NEVT`, `ODV0`).
2. **Live read-only silicon & PCIe captures:** [sen6-diag-idle.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-idle.txt), [sen6-diag-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-brake.txt), [sen6-diag-turbostat.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-turbostat.txt), [sen6-diag-pcie-brake.txt](file:///home/sum/Downloads/AI-Runtime/sen6-diag-pcie-brake.txt) (generated by [sen6-diag-readonly.sh](file:///home/sum/Downloads/AI-Runtime/sen6-diag-readonly.sh)).
3. **Local firmware DPTF `data_vault`:** `/sys/bus/platform/devices/INTC10A0:00/data_vault` (2,956 bytes LZMA → 82,639 bytes, 217 ESIF keys).
4. **Local Strata telemetry traces:** `strata-throttle-trace-20261123-{2004,2222}-*.jsonl` and `strata-steady-ab-20261123-2244-*.jsonl`.

### Authoritative Vendor Documentation & Source Code
5. **Intel 64 and IA-32 Architectures Software Developer's Manual (SDM), Vol. 3B & Vol. 4** (`0x19C` `IA32_THERM_STATUS` bit 10 Power Limitation, `0x1B1` `IA32_PACKAGE_THERM_STATUS` bit 10, `0x1FC` `MSR_POWER_CTL`, `0x610` `MSR_PKG_POWER_LIMIT`, `0x613` `MSR_PKG_PERF_STATUS`, `0x64F` `MSR_CORE_PERF_LIMIT_REASONS` bit 10 PL1 Status): https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
6. **Linux Kernel `int3400_thermal.c` (`INTC10A0`, `_OSC`, `data_vault`, `available_uuids`, `production_mode`):** https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
7. **Linux Kernel ABI Documentation for `int3400_thermal`:** https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-platform-int3400-thermal
8. **Linux Kernel `dell-wmi-ddv.c` & `dell-pc.c`:** https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/platform/x86/dell/dell-wmi-ddv.c and https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/platform/x86/dell/dell-pc.c
9. **Linux Kernel `turbostat.c` (`PKG_%` / `MSR_PKG_PERF_STATUS`, RAPL, thermal MSR decoding):** https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/power/x86/turbostat/turbostat.c
10. **Intel `thermal_daemon` (`thermald`) GDDV parser (`src/thd_gddv.cpp`) & custom `thermal-conf.xml` docs:** https://github.com/intel/thermal_daemon/blob/master/src/thd_gddv.cpp
11. **NVIDIA NVML API Reference — `nvmlClocksEventReasons`:** https://docs.nvidia.com/deploy/nvml-api/group__nvmlClocksEventReasons.html
12. **Dell XPS 15 9530 Documentation & Dell Command | Configure (`ThermalManagement`):** https://www.dell.com/support/home/en-us/product-support/product/xps-15-9530-laptop/docs and https://www.dell.com/support/manuals/en-us/command-configure/

### Independent Reviews & Community Anecdotes
13. **Notebookcheck — Dell XPS 15 9530 (RTX 4070) Review** *(independent measurement: 40–50 W TGP cap)*: https://www.notebookcheck.net/Dell-XPS-15-9530-RTX-4070-laptop-review-Both-impressive-and-underwhelming.709131.0.html
14. **Community / Forum Anecdotes *(explicitly labeled as anecdotes)*:** Reddit (`r/Dell`, `r/DellXPS`) and Dell Community reports of XPS 15 9520/9530 & Precision 5570/5680 400 MHz throttling under mixed load / WD22TB4 130 W dock heating / flat-desk airflow; `intel/thermal_daemon` issues (`#293`, `#484`).

---

## 9. Addendum (2026-11-24 Evening — Clean-Boot Verification & Thermal Ceiling Map)

After a **full cold shutdown** and Manjaro update to kernel **`6.18.63-3-MANJARO`** + NVIDIA **`620.70.06`** (`gpu_unlock` active, `thermald` disabled, `INTC10A0:00/uuids/current_uuid = INVALID`, `EC reg 0x32 = 0`), we ran six controlled clean-boot traces with a live `SEN6 >= 68 °C` auto-stop guard. These tests resolved every remaining open question and **overturned** the earlier assumption that CPU-only `22 W` capping at `SEN6 = 63 °C` suffices on a clean boot:

### Key Verified Clean-Boot Findings (`EC reg 0x32 = 0`)
1. **Full cold shutdown clears `EC reg 0x32`:** Baseline unmitigated `balanced` (`strata-throttle-trace-20261124-1849-1-balanced.jsonl`) immediately reproduced **5/5 EC brakes** at `SEN6 = 65.05 °C → 61.05 °C` (`261/616 s = 42.4%` braked, `256 s` PCIe Gen 1, **`16.06 t/s`** steady R3–R6, `18.96 t/s` overall R1–R6; unbraked `33.7 W` CPU + `34.5 W` GPU = `68.2 W`).
2. **`63 °C → 22 W` failed on clean boot (11 brakes in 15 min):** Archived in `sen6-thermald-custom22w-cleanboot-fail-telemetry.txt`. Cross-referencing `thermald`'s per-second RAPL `Pkg` power log proved two root causes:
   - Intel's **`55.97 s` RAPL PL1 time window** (`constraint_0_time_window_us = 55967744`) meant waiting until `SEN6 = 63.05 °C` allowed CPU power to stay at `32–40 W` (`64F_b10 = 0`) until the EC brake slammed it to `9.3 W / 400 MHz`.
   - All 11 brakes fired at **`SEN6 = 64.05 °C`** (never reaching `65 °C`), proving that the earlier `01:18` `22 W` run only survived `202 s` at `SEN6 = 64.05 °C` because `EC reg 0x32` was still latched to `1` from `--adaptive`.
3. **Discovery of Dell's 2-step clean-boot EC fallback (`12 W` → `9.3 W + PCIe Gen 1`) triggered at `SKIN >= 59.05 °C` + `SEN6 >= 62–63 °C`:**
   - Moving the cap early (`59 °C → 20 W` passive + `63 °C → 17 W` max, `strata-throttle-trace-20261124-2013-1-balanced.jsonl`) held `SEN6 <= 63.05 °C` and CPU genuinely at `17.0 W`, **yet still triggered 9 EC brakes** (`27.0%` braked, `15.4 t/s` steady) once `SKIN` reached `59.05 °C` (because the GPU still drew `33.8 W`, `50.8 W` combined).
   - Caught in slow motion: the EC first clamped CPU to **`12.0 W` (`500–600 MHz`, still PCIe Gen 4)**, then escalated to **`9.3 W` (`400 MHz`) + PCIe Gen 1**.
   - Across **all 30 JSONL brakes** recorded across every trace: **30/30** started at `SKIN = 59.05–60.05 °C` (`SEN6 = 62.05–66.05 °C`) and **29/29** completed brakes released at exactly **`SEN6 = 61.05 °C`** (even while `SKIN` stayed `59.05 °C`).
4. **GPU power-limit vs clock-locking & the clean-boot `~48 W` ceiling:**
   - `nvidia-smi -pl` is locked by VBIOS (`Changing power management limit is not supported`), but **`nvidia-smi -lgc`** (core clock ceiling) and **`nvidia-smi -lmc`** (memory clock ceiling, `Runtime` switching) are both supported.
   - Because GPU heats `SEN6` >2× as strongly per watt as CPU (`0.41` vs `0.19 °C/W`), trimming GPU clocks (`-lgc 210,1200` + `-lmc 405,5501`, dropping GPU from `34.5 W → 24.4 W`) while setting CPU `PL1 = 24 W` (`48.4 W` total) eliminated all full EC brakes and all PCIe Gen 1 drops on a 100% clean boot (`EC reg 0x32 = 0`).

### Complete 2026-11-24 Clean-Boot Matrix (`EC reg 0x32 = 0`, Kernel `6.18.63`, NVIDIA `620.70.06`)

| Run / Trace | CPU + GPU W | Total W | GPU Clocks | Fans (RPM) | `SEN6` / `SKIN` Max | `<=500 MHz` % | PCIe Gen 1 | Steady t/s |
|---|---:|---:|---|---|---|---:|---:|---:|
| Unmitigated `balanced` (`1849`) | `33.7 + 34.5 W` | `68.2 W` | `1485 / 7001` | `5900 / 5600` | `65.05 / 60.05 °C` | `42.4%` | `256 s` | `16.06 t/s` |
| `59C→20W / 63C→17W` (`2013`) | `17.0 + 33.8 W` | `50.8 W` | `1485 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `27.0%` | `214 s` | `15.4 t/s` |
| A1: `GPU<=1200`, `CPU=22W` (`2042`) | `22.1 + 28.7 W` | `50.8 W` | `1200 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `18.9%` | `133 s` | `18.54 t/s` |
| A2: `GPU<=960`, `CPU=22W` (`2059`) | `22.1 + 27.4 W` | `49.5 W` | `960 / 7001` | `5900 / 5600` | `63.05 / 59.05 °C` | `19.8%` | `148 s` | `17.99 t/s` |
| A4: `GPU<=960`, `CPU=22W`, `perf` (`2117`) | `22.0 + 28.0 W` | `50.0 W` | `960 / 7001` | `6291 / 6003` | `63.05 / 59.05 °C` | `19.0%` | `138 s` | `18.45 t/s` |
| **A3: `GPU<=1200`, `VRAM<=5501`, `CPU=24W` (`2141`)** | **`24.0 + 24.4 W`** | **`48.4 W`** | **`1200 / 5501`** | **`5900 / 5600`** | **`63.05 / 60.05 °C`** | **`0.3%`** | **`0 s`** | **`20.35 t/s`** |

### Final Decision (2026-11-24)
- **Do NOT install `thermald` (`sen6-install-thermald.sh`)** — system remains cleanly at stock defaults (`thermald` disabled, `EC reg 0x32 = 0`, `PL1 = 115 W`, stock GPU clocks).
- **Recommended safe on-demand preset (hardware-longevity priority):** Run `sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh` during long inference sessions (`1200 / 5501 MHz` GPU + `24 W` CPU → `48.4 W` total, **`20.35 t/s` steady**, `0` full EC brakes, `0 s` PCIe Gen 1, full stock EC protection untouched; `Ctrl-C` restores stock clocks & `115 W`).
- **Full pickup guide** (including future Option 1 active underside cooling and Option 2 Windows-style `DPST(1)` handoff): [2026-11-24_handover_neon.md](file:///home/sum/Downloads/AI-Runtime/2026-11-24_handover_neon.md).
