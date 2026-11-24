# Handover: Dell XPS 15 9530 `SEN6` 400 MHz Throttle Investigation (`neon`)

**Date:** 2026-11-24 (02:03 AEDT)  
**Workspace:** `/home/sum/Downloads/AI-Runtime`  
**Git branch:** `xps15-sen6-research` (tracking `origin/xps15-sen6-research` → `https://github.com/SvenMeyer/xps15-9530-inference.git`, **PUBLIC repo**)  
**Latest Neon commit:** `a89c2b0` (`Address peer-review feedback: tighten claims and require clean-boot soak before install`)

---

## 1. Current Status & Exact Next Steps (Start Here)

> [!CAUTION]
> **Safety Gate — Do NOT run heavy loads or `sen6-install-thermald.sh` until after a full cold shutdown!**  
> During Test 1 (`00:54`), `thermald --adaptive` invoked `IETM._OSC` → `ECDV.DPST(One)`, which writes `1` to `EC reg 0x32` (`EC_DPTF_STATE_ENABLE`). Dell's ACPI code has **no path to clear that flag** (`Ctrl-C` restores RAPL PL1 to `115 W` but does **not** clear `EC reg 0x32`). Afterward, during a misconfigured custom run (`<Preference>PERFORMANCE</Preference>`), `SEN6` sat at `65–66 °C` for `64 s` (`24 s` at `66 °C`) without the `65 °C` brake firing (vs `≤47 s` previously). We must confirm the hardware fallback brake returns on a clean cold boot before trusting or installing any software policy.

### Step-by-Step Resume Plan
1. **User — Full cold shutdown:** Power the laptop off completely (not a warm reboot) to clear `EC reg 0x32`.
2. **User — Brake-return check (clean boot, NO `thermald`):**
   ```bash
   bash /home/sum/Downloads/AI-Runtime/strata-throttle-trace.sh
   ```
   *(Or run 1 balanced arm.)* Confirm that the `400 MHz` brake returns when `SEN6` hits `65.05 °C`.  
   - **If it does NOT return:** Stop heavy loads and investigate immediately.
3. **User + Agent — Clean-boot ≥30-minute soak of custom `22 W` policy (DO NOT run `adaptive`!):**
   - User starts foreground `thermald` (does **not** call `--adaptive` / `_OSC` / `DPST(1)`; `Ctrl-C` restores `115 W` PL1 cleanly):
     ```bash
     sudo /home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh custom
     ```
     Outputs: `sen6-thermald-custom.log`, `sen6-thermald-custom-telemetry.txt`.
   - Agent drives a ≥30-minute Strata balanced workload (same model/flags as `strata-throttle-trace.sh` / `strata-throttle-trace.py`) and logs per-second telemetry + t/s.
   - **Pass criterion:** `0 s` at `400 MHz`, `0 s` PCIe Gen 1, `SEN6 < 65 °C` across the full ≥30-min soak, steady decode `~24–25+ t/s`.
   - **Tuning fallback:** Because the initial 5.5-min run peaked at `SEN6 = 64.05 °C` (`~1 °C` margin at `25 °C` room temp), if `SEN6` creeps to `65 °C` over 30 min, lower `<TargetState>` in [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) from `22000000` (`22 W`) to `20000000` (`20 W`) and re-soak.
4. **User — Persistent install (ONLY after Step 3 passes):**
   ```bash
   sudo /home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh
   ```
   - Installs `/etc/thermald/thermal-conf.xml` and `/etc/systemd/system/thermald.service.d/override.conf` (drops Manjaro's default `--adaptive` flag), enables & starts `thermald.service`, logs to `sen6-install-thermald.log` (keep local/uncommitted).
   - **1-command rollback anytime:**
     ```bash
     sudo /home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh
     ```
5. **Follow-up (optional after persistent install):**
   - Optional synergy test: custom `SEN6` policy + `performance` fan curve (~6300/6000 RPM vs ~5900/5600 RPM in `balanced`) to see if `24–26 W` stays below `SEN6 = 64 °C`.
   - Resume the 24-run Strata `0.2.20` benchmark suite (`strata-suite-0220.sh`), verifying `~12.7 GB/s` PCIe Gen 4 in the engine log.

---

## 2. Machine, Environment & Repository State

- **Hardware:** Dell XPS 15 9530 (`0PKR91`), Intel i7-13700H, NVIDIA RTX 4070 Laptop 8 GB, BIOS `1.34.0` (downgrade blocked; BIOS settings survived update from `1.13.0`), Manjaro Linux kernel `6.12.112-1-MANJARO`.
- **Physical setup:** USB-C power only (no DC barrel jack; 2 left TB4 ports, 1 right USB-C 3.2 Gen 2 port), laptop already lifted ~2 cm for underside airflow, powered by Dell WD22TB4 dock on left USB-C (only >65 W PSU on hand). Battery at `100%` / `Not charging` (`PrimaryBattChargeCfg=PrimAcUse`).
- **Kernel cmdline notes:** Includes `pcie_aspm=force`, `nvidia.NVreg_DynamicPowerManagement=0x00`, and `gpu_unlock.targets=0000:01:00.0` (tensor-core multiplier unlock only; does not raise the ~34–39 W GPU power cap).
- **Package state:** `extra/thermald` (`2:2.5.13-1`) is installed; `thermald.service` is **disabled and stopped**. `strata` is stopped.
- **Git notes:**
  - Branch `xps15-sen6-research` is pushed through commit `a89c2b0`.
  - `2026-11-23-xps15-sen6-research-result-opus-5.5.md` has separate uncommitted local edits made by another session (Opus 5.5) — **do not overwrite or revert it**.
  - **Public repo hygiene:** NEVER stage or push disk/LUKS UUIDs (`sen6-diag-turbostat.txt` — Opus committed a redacted copy at `xps15-sen6-research/sen6-diag-turbostat-redacted.txt`), `BIOS-Check_1.13.0.txt`, raw ACPI dumps, `sen6-thermald-*.log`, `sen6-install-thermald.log`, or any API keys.

---

## 3. Proven Findings vs. Inferences (Do Not Re-Investigate)

Full report with all register dumps, ACPI lines, and citations: [2026-11-23-xps15-sen6-research-result-neon.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-neon.md)

| Finding | Status | Source |
|---|---|---|
| **`SEN6` = `"Charger Temperature Sensor(QE10)"`** (EC index `0x07`, live ACPI `_HOT=65.05 °C`, `_CRT=70.05 °C`). `SEN9` = `"VR_GPU&CPU(QE16)"` (`75 °C` max vs `94 °C` hot — **VRM is healthy**, NOT overheating). | **100% Proven** | `/tmp/acpi-dump/SSDT4.dsl` `_STR`, `sen6-diag-brake.txt` |
| **400 MHz brake is a CPU package/platform PL1 power limit, NOT `BD PROCHOT`.** Every `PROCHOT` active/sticky bit (`0x19C` b2/3, `0x1B1` b2/3, `0x64F` b0/16) stayed `0` across both captured brakes and the whole boot. Instead, **bit 10 (`0x0400`)** flipped `0 → 1` simultaneously in `0x19C`, `0x1B1`, and `0x64F` while `turbostat` logged `PKG_% = 101.89%` at `PkgWatt = 9.18 W`, `Bzy_MHz = 400`, `UncMHz = 400`, `CoreThr = 0`, `SMI = 0`, even while MSR `0x610` and MMIO `0x59A0` still read `115 W`. | **100% Proven** | `sen6-diag-brake.txt`, `sen6-diag-turbostat.txt` |
| **Hidden limiter is EC PECI RAPL PL1** (`9.18 W` is measured package draw at `400 MHz`, not a directly read EC register). | **Strong inference** | Cannot read PECI PL1 domain directly from Linux |
| **PCIe Gen 4 → Gen 1 is NOT `pcie_aspm=force`.** `00:01.0` (`PEG010`) reports `ASPM not supported`/`Disabled` on both ends. Mid-brake, `00:01.0` `LnkCtl2: Target Link Speed` drops `16GT/s → 2.5GT/s` (`1–2 s` *after* CPU hits 400 MHz) and restores to `16GT/s` at `0 s` lag on release, with zero NVML HW slowdown/power-brake bits (`0x08`/`0x40`/`0x80`). | **100% Proven** | `sen6-diag-pcie-brake.txt`, `sen6-diag-brake.txt` |
| **ACPI SSDT override of `SEN6` `_HOT` cannot move the EC cutoff.** `S7HP = 0x41` (`65 °C`) and `S7CC = 0x46` (`70 °C`) are static AML constants never written back to the EC. | **100% Proven** | `SSDT4.dsl` |
| **Linux is missing Windows Intel DTT gradual PL1 control.** Decoded 82,639-byte `INTC10A0:00/data_vault` leaves `SEN6` disabled (`90.1 °C` placeholder) and clamps CPU PL1 smoothly on `SKIN` (`46.1–55.1 °C → 45–20 W`) and `SEN5` (`ITMT 62.1 °C → 15 W`, `PSVT 58.1–74.1 °C → 15–13 W`). | **100% Proven** | `INTC10A0:00/data_vault` LZMA decode |

---

## 4. Benchmark Summary & `thermald` Gotchas Already Solved

### Standardized Balanced Strata Benchmark Results
| Run | Steady Decode (capped) | Overall Decode | `400 MHz` Brake | PCIe Gen 1 | `SEN6` Max | Notes |
|---|---:|---:|---:|---:|---:|---|
| Unmitigated `balanced` (warm) | `17.4–19.6 t/s` | `17.4–19.6 t/s` | `169–184 s` (3–4 brakes) | `163–179 s` | `65.05 °C` | Baseline sawtooth |
| Test 1: `thermald --adaptive` (Dell GDDV) | `17.24 t/s` (R3) | `20.68 t/s` (3 rounds) | `0 s` | `0 s` | `62.05 °C` | Clamped `PL1_mmio` to `15 W` on `SEN5 > 62 °C`; set `EC reg 0x32 = 1` |
| Test 2: `thermald` custom (`SEN6 63 °C → 22 W`) | **`24.01` (R3) / `25.49` (R4) t/s** | `26.28 t/s` (4 rounds incl. pre-cap R1–R2) | **`0 s`** | **`0 s`** | `64.05 °C` | **Promising, not yet soak-proven:** single ~5.5-min run taken *after* `EC reg 0x32` was set, `~1 °C` margin |

### `thermald` Gotchas Already Solved (Keep in Mind)
1. **`--config-file` ownership (`EPERM`):** `thermald` refuses custom XML files not owned by `root:root`. [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) stages `sen6-thermald-custom.xml` to `/tmp/sen6-thermald-custom.xml` via `install -o root -g root -m 0600` and checks `ZONE DUMP BEGIN` in the log.
2. **`<Preference>QUIET</Preference>` is required:** With `<Preference>PERFORMANCE</Preference>` (`pref 1`), `thermald` skips passive trips (`type 3`). `<Preference>QUIET</Preference>` (`pref 0`) activates passive trips and does **not** alter Dell's BIOS `platform_profile`.
3. **Manjaro systemd default `--adaptive`:** `/usr/lib/systemd/system/thermald.service` passes `--adaptive` by default, which ignores custom XML and triggers `DPST(1)` + the `15 W` `SEN5` clamp. [sen6-install-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh) overrides `ExecStart` via `/etc/systemd/system/thermald.service.d/override.conf` to drop `--adaptive` and pass `--config-file=/etc/thermald/thermal-conf.xml`.

---

## 5. Key Files Index

- **Reports:**
  - [2026-11-23-xps15-sen6-research-result-neon.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-neon.md) — full primary report (updated for peer review in `a89c2b0`).
  - [2026-11-23-xps15-sen6-research-result-neon-web.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-neon-web.md) — independent web-only cross-check report.
  - [2026-11-23-xps15-sen6-research-result-opus-5.5.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-research-result-opus-5.5.md) — Opus 5.5 report & peer review.
  - [2026-11-23-xps15-sen6-throttle-evidence.md](file:///home/sum/Downloads/AI-Runtime/2026-11-23-xps15-sen6-throttle-evidence.md) — original baseline evidence log.
- **Scripts & Configs:**
  - [sen6-thermald-custom.xml](file:///home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml) — `QUIET`, `SEN6 63 °C → 22 W` (`1 °C` hyst) via `rapl_controller_mmio`.
  - [sen6-test-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh) — foreground reversible `sudo` runner (`custom` or `adaptive`; **only use `custom`** going forward).
  - [sen6-install-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh) — persistent systemd installer (run only after clean-boot 30-min soak passes).
  - [sen6-uninstall-thermald.sh](file:///home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh) — 1-command rollback.
  - [sen6-diag-readonly.sh](file:///home/sum/Downloads/AI-Runtime/sen6-diag-readonly.sh) — read-only MSR/PCIe/ACPI/turbostat diagnostic script.
  - [strata-throttle-trace.sh](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace.sh) & [strata-throttle-trace.py](file:///home/sum/Downloads/AI-Runtime/strata-throttle-trace.py) — standardized Strata trace harness.

---

## 6. Standing User Constraints & "Do Not Do This"

- **User `sudo` workflow rule:** Agent has no `sudo`. Always write any `sudo` commands into a script file, tell the user the exact filename to run as `sudo`, and define the output filename so the agent can read and process it.
- **Do NOT** disable `BD PROCHOT` (`wrmsr 0x1FC` bit 0) — proven 0% effective here.
- **Do NOT** patch `SSDT4` `_HOT` via initrd ACPI override — proven 0% effective (`S7HP` is never sent to EC).
- **Do NOT** run `sen6-test-thermald.sh adaptive` or Manjaro's default `thermald --adaptive` before or during clean-boot testing (latches `EC reg 0x32 = 1` until cold shutdown).
- **Do NOT** tear down the heatsink for VRM pads expecting to fix `SEN6` (`SEN9` VRM is only `75 °C`).
