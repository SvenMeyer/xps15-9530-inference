# 2026-11-23-xps15-sen6-research-result-neon-web

## 1. Short Conclusion & Confidence Level

* **Most likely mechanism (High confidence for the CPU brake; Medium confidence for the exact PCIe Gen 1 path):** The 400 MHz cliff is an **embedded-controller (EC) external `PROCHOT#` / `BD PROCHOT` assertion** triggered when the board sensor exposed as `SEN6` / `dell_ddv temp8` ("Ambient") stays at or above its **65.05 °C** firmware hot limit past a dwell window, releasing only at **61.05 °C**. Because `thermald` is not running and `INT3400` has no active policy (`current_uuid=INVALID`), Linux never applies the OEM's gradual Intel DTT/DPTF power-limiting curve from `data_vault` (`GDDV`), allowing sustained ~66 W combined CPU+GPU load to heat the board straight into the EC's hard fail-safe. The concurrent drop of the RTX 4070 link to **PCIe Gen 1** is most likely either a secondary consequence of the CPU stalling at 400 MHz (starving the GPU so NVIDIA's PowerMizer / ASPM drops link speed) or an EC/GPU thermal-brake signal; it is not yet proven which without checking `nvidia-smi` throttle reasons during a stall.


* **Physical identity of SEN6 (Low-to-Medium confidence — unconfirmed without ACPI/board inspection):** Dell does not publish a board schematic mapping `SEN6` on the XPS 15 9530. In Linux's `dell-wmi-ddv` driver, the `"Ambient"` label is explicitly noted as `/* sometimes called SKIN */` ([Linux `dell-wmi-ddv.c](https://biggrinrtx.com/hub/x/ezpz/kilroy/linux/drivers/platform/x86/dell/dell-wmi-ddv.c)`). On XPS 15 9500–9530 boards, the 65 °C hot / 70 °C critical threshold and 400 MHz lock strongly match either a **chassis/skin-area board thermistor** or a **VRM/power-delivery neighborhood sensor** heated by poorly cooled MOSFETs under Dell's factory insulating mesh (anecdotal owner reports on [r/DellXPS](https://www.reddit.com/r/DellXPS/comments/17nac28/considering_buying_the_15_is_cooking_a_real_issue/) and [r/DellXPS 9530](https://www.reddit.com/r/DellXPS/comments/1n0nqmw/dell_xps_15_9530_thermal_throttling_management/)).
* **Why software overrides won't move the 65 °C wall (High confidence):** Changing ACPI tables or Linux sysfs does **not** raise an EC-enforced hardware trip point. Furthermore, on 12th/13th-gen Intel mobile platforms (including Raptor Lake-H), **`BD PROCHOT` (`MSR 0x1FC` bit 0) is typically firmware-locked at boot** (and even if unlocked, disabling it would mask real VRM/charger/battery over-temperature protection).
* **Primary path forward:** First prove the mechanism with read-only MSR (`0x19C`, `0x1B1`, `0x1FC`, `0x64F`), `turbostat`, `nvidia-smi`, and `acpidump` / `data_vault` checks. Then test **`thermald --adaptive`** (which reads `/sys/bus/platform/devices/INTC10A0:00/data_vault`) to restore gradual OEM power scaling before the 65 °C cliff, and inspect the physical VRM/heatsink contact and airflow if `SEN6` still climbs too fast.

---

## 2. Detailed Findings (Questions 1–7)

### Q1. What is SEN6 physically on the XPS 15 9530, and what does exceeding 65 °C risk?

* **Verified facts:**
* On your machine, `SEN6` matches `dell_ddv temp8` (`"Ambient"`) and `dell_smm temp8`, with firmware trip points `hot = 65.05 °C`, `hysteresis = 4.00 °C`, `critical = 70.05 °C`.


* In the Linux kernel's `drivers/platform/x86/dell/dell-wmi-ddv.c`, the sensor type string `"Ambient"` carries the inline comment `/* sometimes called SKIN */` ([`dell-wmi-ddv.c`](https://biggrinrtx.com/hub/x/ezpz/kilroy/linux/drivers/platform/x86/dell/dell-wmi-ddv.c)).
* Dell's official XPS 15 9530 documentation does **not** publish the physical PCB coordinates of `SEN1`–`SEN9` ([Dell XPS 15 9530 Setup and Specifications](https://m.media-amazon.com/images/I/B128v4fC5iL.pdf)).


* **Inference & unconfirmed details:**
* A **65 °C hot / 70 °C critical** trip is too low to be a MOSFET junction temperature (VRMs are typically rated to 105–125 °C) or CPU/GPU die temp, and matches either (a) a **PCB/ambient thermistor near the VRM, charger/USB-C PD stage, or battery**, or (b) an **internal chassis/skin proxy thermistor** (UL/IEC 62368-1 skin-temperature limits for metal/composite enclosures are much lower than silicon limits, and PCB thermistors sit hotter than the outer skin). Note that your `SKIN` zone already exists separately with `hot = 82.05 °C`, which makes `SEN6` more likely to be a **board/ambient thermistor near a heat-sensitive zone (battery, USB-C PD/charger, SODIMM/PCB, or VRM neighborhood)** rather than the main CPU/GPU die.


* **Could not be confirmed:** Exact PCB location of `SEN6`. Decompiling `DptfTabl` (checking the `_STR` Unicode string or participant comments on `SEN6`) and comparing `SEN6` against an IR thermometer scan of the bottom case / keyboard deck is required to pin it down.
* **Risk of exceeding 65 °C:** If `SEN6` is a thermal proxy for the **Li-Po battery** (cells degrade rapidly and risk swelling above ~45–60 °C), **USB-C PD / charger ICs**, or **uncooled VRM MOSFETs** (whose local die temp can be 30–50 °C hotter than a nearby PCB thermistor), bypassing the 65 °C limit risks accelerated battery swelling, solder/component degradation, or VRM failure.



### Q2. What mechanism forces 400 MHz and PCIe Gen 1?

* **Verified facts:**
* Intel's `IA32_THERM_STATUS` (`MSR 0x19C`) and `IA32_PACKAGE_THERM_STATUS` (`MSR 0x1B1`) separate internal thermal throttling (**bit 0** = Thermal Status, **bit 1** = Thermal Log) from external/bidirectional **`PROCHOT#` / `FORCEPR#**` (**bit 2** = PROCHOT Status, **bit 3** = PROCHOT Log) ([Linux Kernel Internals – Thermal Management](https://kernel-internals.org/power/thermal/); [Skylake/SDM MSR breakdown](https://benchaffin.com/skylake/skylake.html)).
* `MSR_CORE_PERF_LIMIT_REASONS` (`MSR 0x64F`) records active core frequency-clipping reasons in bits 0–15 and sticky logs in bits 16–31: **bit 0** = PROCHOT active (**bit 16** = PROCHOT log), **bit 1** = Thermal active (**bit 17** = Thermal log), **bit 5/21** = RATL, **bit 6/22** = VR Thermal Alert, **bit 10/26** = PL1, **bit 11/27** = PL2 ([Intel Community – MSR 0x64F / SDM Vol. 4](https://community.intel.com/t5/Software-Tuning-Performance/Intel-Thermal-MSR/td-p/1653821?profile.language=en); [Framework EC BD PROCHOT issue showing `0x64F = 0x10001](https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker/issues/266)`).
* On Linux, the kernel's `package_throttle_count` / `package_throttle_total_time_ms` counts internal package thermal-monitor interrupts; an external EC-asserted `BD PROCHOT` forces the CPU to its lowest LFM/minimum ratio (**400 MHz** on Raptor Lake-H) **without** incrementing internal package thermal throttle counters—matching your trace showing **165 s at 400 MHz with only 18 ms of package thermal throttling**.


* On NVIDIA Linux drivers, PowerMizer automatically drops the PCIe link from Gen 4 to **Gen 1** when GPU utilization / bus traffic drops ([NVIDIA Developer Forums](https://forums.developer.nvidia.com/t/not-getting-full-bandwidth-pcie-transfers/232317)).


* **Inference:**
* **CPU 400 MHz:** Almost certainly **EC-asserted `PROCHOT#` (`BD PROCHOT`)** triggered by `SEN6 >= 65 °C` (with a 12–36 s firmware dwell/averaging window) and cleared at `SEN6 <= 61 °C`.
* **PCIe Gen 1:** Two competing hypotheses: (1) When the CPU stalls at 400 MHz during Strata MoE CPU-expert compute, PCIe/GPU traffic collapses and NVIDIA PowerMizer steps the link down to Gen 1; or (2) the EC simultaneously asserts a GPU power/thermal brake (`SW Thermal Slowdown` / `HW Slowdown` in `nvidia-smi`). Note your separate observation where the link stayed stuck at Gen 1 until reboot—that points to a driver/link-retraining quirk or sticky NVIDIA P-state/ASPM state rather than normal hysteresis.




* **How to interpret the read-only checks during a stall:**
* `rdmsr -p 0 0x19C` and `rdmsr -p 0 0x1B1`: Check **bit 2 (`0x4`)** = `1` while **bit 0 (`0x1`)** = `0`. That proves **external `PROCHOT#**` rather than CPU die thermal throttling.
* `rdmsr -p 0 0x64F`: Check **bit 0 (`0x1`)** = `1` (PROCHOT active) and **bit 6 (`0x40`)** (VR Thermal Alert). If `0x64F` shows bit 0 = 1 and bits 1, 10, 11 = 0, external PROCHOT is the sole active limiter.
* `rdmsr -p 0 0x1FC`: Check **bit 0 (`0x1`)** = `1` (BD PROCHOT enabled).
* `turbostat`: Watch `Bzy_MHz` (drops to ~400), `CoreTmp`/`PkgTmp` (below 100 °C), `PkgWatt` (plummets), `PKG_%` (0% if not RAPL-limited), and `SMI` (check if SMM interrupts spike at the transition) ([`turbostat(8)` man page](https://manpages.ubuntu.com/manpages/xenial/man8/turbostat.8.html)).



### Q3. Can the 65 °C limit be raised or the response softened safely?

| Lever | Affects EC 65 °C decision, or Linux display only? | Assessment & Evidence |
| --- | --- | --- |
| **BIOS `ThermalManagement**` (`Optimized`, `Cool`, `Quiet`, `UltraPerformance`) | **Affects EC** (fan curves & PL1/PL2/thermal targets), but **does not raise** the 65 °C fail-safe in a way that eliminates the cliff. | Anecdotal XPS 15 9520/9530 reports confirm `UltraPerformance` raises sustained power limits (e.g., 45 W → 55 W) and fan aggressiveness, which can heat `SEN6` *faster* if cooling is saturated, and still hits 400 MHz throttling ([Arch Linux Forums – XPS 15 9520](https://bbs.archlinux.org/viewtopic.php?id=282002); [r/DellXPS](https://www.reddit.com/r/DellXPS/comments/wa4uky/dell_xps_15_9520_i9_cinebench/)). Your own traces already showed Linux `performance` heats `SEN6` nearly 2× faster.

 |
| **Dell Command | Configure (`cctk`) / `smbios-thermal-ctl**` | **Affects EC** thermal mode selection only. | Exposes the same four BIOS ThermalManagement profiles (`Optimized`, `Cool`, `Quiet`, `UltraPerformance`) from Linux. It cannot edit individual `SEN6` trip points. |
| **Dell WMI / SMM (`dell_smm`, `dell_ddv`)** | **Read-only** for `dell_ddv`; `dell_smm` fan control is locked/overridden by BIOS EC on modern XPS models. | Confirmed by kernel ABI (`dell-wmi-ddv` is read-only telemetry) ([Linux Kernel ABI docs](https://docs.kernel.org/admin-guide/abi-testing-files.html)). |
| **DPTF Data Vault (`GDDV` / `INTC10A0:00/data_vault`)** | **Softens response via OS** (`thermald --adaptive`), does **not** raise the EC hardware trip. | `data_vault` holds Dell's OEM DTT passive throttling tables ([Intel `thermal_daemon` `DEVELOPER.md](https://github.com/intel/thermal_daemon/blob/master/DEVELOPER.md)`). Reading/applying it lets Linux throttle PL1 smoothly *before* `SEN6` reaches 65 °C. |
| **ACPI SSDT override via initrd (`DptfTabl`)** | **Linux OS display & OS-driven passive trips only.** | Editing `DptfTabl` changes what the Linux thermal subsystem sees, **not** the hardcoded EC firmware loop that polls `SEN6` over SMBus/ADC and asserts `PROCHOT#`. |
| **EC register / firmware modification** | Would affect EC, but **undocumented, signed, and unsafe**. | Dell XPS 15 9530 EC firmware is signed inside the BIOS capsule and has no documented user-tunable trip register. |

### Q4. Is Linux missing the policy Windows uses?

* **Verified facts:**
* On Raptor Lake, `INTC10A0` is the Intel DPTF/DTT platform device (`drivers/thermal/intel/int340x_thermal/int3400_thermal.c`) that exposes the OEM's binary thermal policy table at `data_vault` ([Linux `int3400_thermal.c](https://github.com/torvalds/linux/blob/master/drivers/thermal/intel/int340x_thermal/int3400_thermal.c)`; [Linux `intel_dptf.rst](https://kernel.googlesource.com/pub/scm/linux/kernel/git/pcmoore/audit/+/HEAD/Documentation/driver-api/thermal/intel_dptf.rst)`).
* `uuids/current_uuid = INVALID` and `uuids/available_uuids = UNKNOWN` is a known state when no userspace daemon (`thermald --adaptive`) has parsed `data_vault` and taken control, or when firmware relies solely on `GDDV` rather than legacy UUIDs ([`intel/thermal_daemon` #484](https://github.com/intel/thermal_daemon/issues/484)).
* Intel's `thermald` in `--adaptive` mode directly parses `GDDV` (`data_vault`) and applies the OEM's passive trip points and RAPL PL1 limits so the OS throttles gradually **before** hardware `PROCHOT#` fires ([`intel/thermal_daemon` `DEVELOPER.md](https://github.com/intel/thermal_daemon/blob/master/DEVELOPER.md)`). `dptfxtract` is largely superseded by `thermald --adaptive` reading `data_vault` directly (older `dptfxtract` binaries extracted legacy ACPI tables into XML).


* **Inference & caveats:**
* **Yes — Linux is currently running without Dell's gradual DTT policy.** On Windows, Intel Dynamic Tuning Technology (DTT) reads that exact `GDDV` table and smoothly dials back CPU PL1 (e.g., from 45 W down to 25–30 W) as `SEN6` / board sensors climb, keeping `SEN6` below 65 °C rather than slamming into a 400 MHz EC brick wall.
* **Caveat:** `thermald --adaptive` has known edge cases on some platforms where a broken `GDDV` condition or `cpufreq_cooling` / `idle_inject` fallback can itself pin clocks low ([`intel/thermal_daemon` #550](https://github.com/intel/thermal_daemon/issues/550)). Always test `thermald` interactively in the foreground (`--no-daemon --loglevel=info --adaptive`) first so you can observe every action it takes and stop it with `Ctrl+C`.



### Q5. Can BD PROCHOT safely be disabled on this platform (`MSR 0x1FC` bit 0)?

* **Verified facts:**
* On Intel CPUs, `MSR_POWER_CTL` (`0x1FC`) **bit 0** enables/disables Bi-directional `PROCHOT#` ([Intel UEFI Firmware Enabling Guide](https://cdrdv2-public.intel.com/671281/uefi-firmware-enabling-guide-for-the-intel-atom-processor-e3900-series.pdf)).
* On **12th-gen and 13th-gen Intel mobile platforms (Alder Lake / Raptor Lake)**, `BD PROCHOT` is **firmware-locked by BIOS on most laptops** (including Dell, Lenovo, Acer, and Framework), making bit 0 read-only / ignored by hardware ([r/ThrottleStop](https://www.reddit.com/r/ThrottleStop/comments/1np9ovu/how_do_you_change_prochot_in_throttlestop/); [Framework Community – 13th gen locked](https://community.frame.work/t/bd-prochot-on-13th-intel-cpu-stuck-at-400mhz/48328); [Acer Community – i5-13500H locked](https://community.acer.com/en/discussion/743745/cpu-stuck-at-0-39-ghz-on-battery-power-bd-prochot-trigger-swift-go-14-sfg14-71-laptop-with-intel-i5-13500h)).


* **What protections remain vs. what could be damaged:**
* Disabling `BD PROCHOT` (if unlocked) **does not** disable the CPU's own internal 100 °C thermal monitor (`PROCHOT#` / `THERMTRIP#`), so the CPU die itself remains protected.
* However, it **blinds the CPU to every external EC/board thermal and power emergency**—including **VRM MOSFET overheating, USB-C PD/charger over-current/over-temp, and battery over-temp**. Until `SEN6` is physically identified and proven to be a benign skin-comfort sensor, disabling `BD PROCHOT` is **unsafe** (and likely blocked by firmware anyway).



### Q6. Known reports and fixes for XPS 15 9530 / 9520 and siblings

* **Anecdotal owner reports (r/DellXPS, Arch Forums):**
* Multiple XPS 15 **9520 and 9530** owners report sudden **400 MHz CPU drops** under sustained mixed CPU+GPU load, attributing it to **VRM overheating** caused by a **factory insulating mesh / sheet between the heatsink and motherboard** that lifts the heatsink or blocks thermal pad contact on 2+ VRM MOSFETs ([r/DellXPS 9530](https://www.reddit.com/r/DellXPS/comments/17nac28/considering_buying_the_15_is_cooking_a_real_issue/); [r/DellXPS 9520/9530](https://www.reddit.com/r/DellXPS/comments/1hpao06/dell_xps_15_9520_gets_super_slow/); [r/DellXPS 9530 Thermal Management](https://www.reddit.com/r/DellXPS/comments/1n0nqmw/dell_xps_15_9530_thermal_throttling_management/)).
* Several 9530 owners report major reductions in throttling after **removing the insulating mesh under the heatsink**, verifying/fixing heatsink contact on the VRMs, repasting with **PTM7950**, and/or using a sealed-foam cooling pad (e.g., IETS GT500) ([r/DellXPS 9530 Cinebench/mods](https://www.reddit.com/r/DellXPS/comments/12yw2sl/dell_xps_9530_2023_cinebench_r23_score/)).
* Note: Removing the *bottom-cover* insulator or bridging the heatsink to the aluminum bottom panel increases bottom chassis temperature (unsafe for lap use).
* **Dell advisories:** No public Dell engineering advisory was found acknowledging a firmware bug in `SEN6` on the XPS 15 9530.



### Q7. Could this indicate a hardware fault? How to test it?

* **Plausible hardware contributors:**
1. **Poor VRM/heatsink contact or displaced insulating mesh** (common factory defect on XPS 15 9520/9530 per owner teardowns) causing local PCB heat soak around `SEN6`.
2. **Degraded factory thermal paste** (your balanced+p5 run logged 52 s of CPU thermal throttling even at ~32 W CPU), raising heatpipe/chassis soak.


3. **Dock / USB-C PD charging heat:** The WD22TB4 feeds power through a USB-C/Thunderbolt port; if the battery is also charging or the PD controller near `SEN6` is running hot, `SEN6` rises faster.
4. **Miscalibrated sensor:** Unlikely given `SEN6` tracks workload power smoothly (4.5–4.9 °C/min in balanced vs 7.5–9.4 °C/min in performance, staying 56–58 °C in power-saver).




* **How to test non-destructively:**
* Compare `SEN6` ramp rate on **direct Dell 130 W USB-C AC adapter** vs. **WD22TB4 dock** (and with battery charge capped / already full so the charger IC isn't dissipating charge heat).
* Elevate the rear of the laptop by 2–3 cm or blow a desk fan across the bottom intake; if `SEN6` stabilizes below 63 °C and the 400 MHz cliff disappears, the issue is **chassis/VRM heat soak**, not a faulty sensor.
* Use an **IR thermometer** across the bottom panel and keyboard deck at the moment `SEN6` hits 65 °C to locate the hottest spot physically.



---

## 3. Ranked Options (Root-Cause Fixes First, Then Workarounds)

### Rank 1 (Root-Cause Software Fix): Test `thermald --adaptive` to apply Dell's `GDDV` policy

* **What it does:** Restores the OEM Intel DTT thermal/power curve stored in `/sys/bus/platform/devices/INTC10A0:00/data_vault`, allowing Linux to gently trim CPU PL1 *before* `SEN6` reaches 65 °C, avoiding the 400 MHz EC cliff.
* **Exact steps (reversible foreground test first):**
```bash
sudo pacman -S thermald
sudo thermald --no-daemon --loglevel=info --adaptive

```


Run your Strata trace in another terminal and watch whether `thermald` loads `GDDV`, lowers PL1 smoothly, and prevents `SEN6` from crossing 65 °C.
* **Expected effect:** Smooth, modest PL1 reduction instead of 45–77 s stalls at 400 MHz (likely higher average tok/s than 19.6 t/s with zero cliffs).
* **Risk:** Low. If `thermald` misbehaves (e.g., pins clocks low as in [`thermal_daemon` #550](https://github.com/intel/thermal_daemon/issues/550)), `Ctrl+C` stops it immediately.
* **Reversibility:** 100% reversible (`Ctrl+C`, or `sudo systemctl disable --now thermald` and reboot if enabled as a service).

### Rank 2 (Root-Cause Hardware Fix): Improve chassis/VRM cooling (external airflow first, then inspect VRM contact/mesh)

* **What it does:** Lowers `SEN6` temperature directly so the EC never approaches 65 °C at ~66 W combined load.
* **Exact steps:**
1. **Zero-risk test:** Elevate the rear of the laptop and direct airflow at the bottom vents, and test with the stock 130 W AC adapter instead of the WD22TB4 dock.
2. **If airflow eliminates the cliff:** Consider a sealed cooling pad (e.g., IETS GT500/Llano) or, if comfortable opening the chassis, inspect whether the factory insulating mesh under the heatsink is lifting the heatsink off the VRM MOSFETs and repaste CPU/GPU with PTM7950 (anecdotal fixes on [r/DellXPS](https://www.reddit.com/r/DellXPS/comments/1n0nqmw/dell_xps_15_9530_thermal_throttling_management/)).


* **Expected effect:** Keeps `SEN6` below 65 °C at full 27–30 t/s decode speed.
* **Risk:** Zero for elevation/cooling pad; Medium for opening the chassis / removing the heatsink (risk of stripping screws, static damage, or hotter bottom case if bottom-cover insulation is removed).
* **Reversibility:** External cooling is 100% reversible; heatsink/mesh modification is physical (keep removed mesh if you want to revert).

### Rank 3 (Targeted Workaround): Cap CPU PL1 or GPU power slightly below the 65 °C equilibrium

* **What it does:** You already observed that `power-saver` keeps `SEN6` at 56–58 °C (13 t/s) while `balanced` (~32 W CPU + ~34 W GPU = ~66 W) climbs to 65 °C (19.6 t/s average with stalls). Finding the exact RAPL PL1 sweet spot (e.g., 22–26 W CPU) or a slightly lower GPU power cap (`nvidia-smi -pl`) should keep `SEN6` parked at ~62–63 °C continuously, yielding steady ~22–25 t/s with zero 400 MHz drops.


* **Exact steps (write operation — temporary until reboot):**
* **Risk:** Very low (reduces heat/power; cannot damage hardware).
* **Undo:** Write back the original `constraint_0_power_limit_uw` value or reboot.
* Example (read current value first):
```bash
cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
echo 25000000 | sudo tee /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw

```




* **Expected effect:** Eliminates 45–77 s stalls while losing far less decode speed than `power-saver`.

### Rank 4 (Diagnostic / Partial Workaround): Test BIOS `ThermalManagement=Cool` or `UltraPerformance`

* **What it does:** `Cool` ramps fans earlier and lowers thermal targets; `UltraPerformance` increases fan speed ceiling (though it may also raise power limits).
* **Risk:** Very low. **Undo:** Set back to `Optimized` in BIOS or via `smbios-thermal-ctl`.

---

## 4. Safe Diagnostic Plan (Read-Only First)

### Phase 1: Strictly Read-Only (Zero System Changes)

1. **Install read-only diagnostic tools** (if not installed):
```bash
sudo pacman -S msr-tools turbostat acpica

```


2. **Load the `msr` kernel module (read-only usage):**
```bash
sudo modprobe msr

```


3. **Capture baseline MSRs and `data_vault` before load:**
```bash
# Read MSRs on CPU 0 (hex):
sudo rdmsr -p 0 -x 0x19C 0x1B1 0x1FC 0x64F
# Copy GDDV data_vault for inspection (no sudo needed):
cp /sys/bus/platform/devices/INTC10A0:00/data_vault ./gddv_data_vault.bin
strings ./gddv_data_vault.bin | grep -E "SEN|SKIN|TCPU|PL1|Quiet|Perf|Cool" | head -n 40

```


4. **Dump and decompile ACPI `DptfTabl` to identify `SEN6`:**
```bash
mkdir -p acpi_dump && cd acpi_dump
sudo acpidump -b
iasl -d ssdt*.dat dsdt.dat
grep -rn "SEN6" *.dsl

```


Look for `_STR` (Unicode description string) and any `_PSV`, `_HOT`, `_CRT`, or `GDDV` references around `Device (SEN6)`.
5. **During an active 400 MHz stall, capture MSRs, `turbostat`, and GPU throttle reasons:**
```bash
# Run in one terminal during a Strata run:
sudo turbostat --quiet --interval 2 --show Time_Of_Day_Seconds,Bzy_MHz,CoreTmp,PkgTmp,PkgWatt,CorWatt,PKG_%,SMI

# The moment Bzy_MHz drops to ~400, run in a second terminal:
sudo rdmsr -p 0 -x 0x19C 0x1B1 0x1FC 0x64F
nvidia-smi --query-gpu=pcie.link.gen.current,pstate,power.draw,temperature.gpu,clocks_event_reasons.active --format=csv

```


* **What proves EC `BD PROCHOT`:** `0x19C` bit 2 = `1` (`& 0x4`), `0x1B1` bit 2 = `1`, `0x64F` bit 0 = `1` (`& 0x1`), while `0x19C`/`0x1B1` bit 0 = `0` and `PKG_%` = `0`.
* **What explains PCIe Gen 1:** Check `clocks_event_reasons.active` and `pstate` in `nvidia-smi`. If `clocks_event_reasons.active` shows `hw_thermal_slowdown` or `sw_thermal_slowdown`, the GPU itself is being throttled; if it shows `gpu_idle` / `P8` with Gen 1, it is merely downclocking because the 400 MHz CPU stopped feeding it.



### Phase 2: Reversible Tests (Only After Phase 1 Confirms the Mechanism)

1. **Airflow & power-source isolation test (zero software writes):** Run one Strata trace with the laptop rear propped up + fan blowing underneath, and one trace on the direct 130 W AC brick (bypassing WD22TB4) with battery full.
2. **Foreground `thermald --adaptive` test (reversible with `Ctrl+C`):**
```bash
sudo thermald --no-daemon --loglevel=info --adaptive

```


Verify whether `thermald` parses `data_vault`, sets RAPL PL1 dynamically, and prevents `SEN6` from hitting 65 °C.

---

## 5. Explicit "Do Not Do This" Items

* **Do NOT disable `BD PROCHOT` (`wrmsr 0x1FC ...`)** — It is very likely hardware-locked on 13th-gen Raptor Lake anyway, and if it *were* writable, clearing bit 0 disables EC protection for VRM, charger, and battery over-temperature while `SEN6`'s physical location is still unknown.
* **Do NOT patch `DptfTabl` / ACPI SSDT via initrd expecting to raise the 65 °C EC cutoff** — The EC reads `SEN6` independently of Linux ACPI; changing ACPI tables only alters what Linux sees and risks breaking `thermald` or hiding real warnings.
* **Do NOT flash unofficial/cross-vendor GPU vBIOSes or modded BIOSes** (mentioned in some Reddit threads) — High brick risk, breaks Secure Boot/firmware signing, and does not fix an EC board-sensor thermal limit.
* **Do NOT remove the bottom-case thermal insulator if you ever use the laptop on your lap**, and do not bridge the heatsink to the bottom cover without understanding that it turns the aluminum baseplate into a hot sink.
* **Do NOT enable `thermald.service` unattended before testing `--no-daemon --adaptive**` — On some Intel platforms, a misparsed `GDDV` entry can trigger `cpufreq_cooling` / `idle_inject` and lock clocks low until `thermald` is stopped and rebooted.

---

## 6. Sources & Evidence Index

* **Linux Kernel Source & Documentation:**
* [`drivers/thermal/intel/int340x_thermal/int3400_thermal.c`](https://github.com/torvalds/linux/blob/master/drivers/thermal/intel/int340x_thermal/int3400_thermal.c) — `INTC10A0` platform device and `data_vault` exposure.
* [`Documentation/driver-api/thermal/intel_dptf.rst`](https://kernel.googlesource.com/pub/scm/linux/kernel/git/pcmoore/audit/+/HEAD/Documentation/driver-api/thermal/intel_dptf.rst) — `INTC10A0` `data_vault` binary thermal table interface.
* [`drivers/platform/x86/dell/dell-wmi-ddv.c`](https://biggrinrtx.com/hub/x/ezpz/kilroy/linux/drivers/platform/x86/dell/dell-wmi-ddv.c) — `"Ambient" /* sometimes called SKIN */` sensor label.
* [Linux Kernel ABI Testing Docs (`dell-wmi-ddv`)](https://docs.kernel.org/admin-guide/abi-testing-files.html) — Read-only debugfs/hwmon interface.
* [`turbostat(8)` Manual](https://manpages.ubuntu.com/manpages/xenial/man8/turbostat.8.html) — Column definitions (`Bzy_MHz`, `CoreTmp`, `PkgTmp`, `PkgWatt`, `PKG_%`).


* **Intel Documentation & `thermald` Source:**
* [`intel/thermal_daemon` `DEVELOPER.md](https://github.com/intel/thermal_daemon/blob/master/DEVELOPER.md)` — How `--adaptive` parses `GDDV` (`data_vault`), dwell times, and fallback behavior.
* [`intel/thermal_daemon` Issue #484](https://github.com/intel/thermal_daemon/issues/484) — `current_uuid=INVALID` / `available_uuids=UNKNOWN` with `data_vault` present.
* [`intel/thermal_daemon` Issue #550](https://github.com/intel/thermal_daemon/issues/550) — Example of `thermald --adaptive` causing 400 MHz `cpufreq_cooling` throttling and MSR/turbostat diagnostic methodology.
* [Intel Community – `MSR_CORE_PERF_LIMIT_REASONS` (`0x64F`) & SDM Vol. 4](https://community.intel.com/t5/Software-Tuning-Performance/Intel-Thermal-MSR/td-p/1653821?profile.language=en) — `0x64F` bit definitions.
* [Linux Kernel Internals – Thermal Management](https://kernel-internals.org/power/thermal/) — `IA32_THERM_STATUS` (`0x19C`) and `IA32_PACKAGE_THERM_STATUS` (`0x1B1`) bit 0 vs. bit 2 (`PROCHOT#`).
* [Intel UEFI Firmware Enabling Guide](https://cdrdv2-public.intel.com/671281/uefi-firmware-enabling-guide-for-the-intel-atom-processor-e3900-series.pdf) — `BiProcHot` (`MSR_POWER_CTL` `0x1FC` bit 0).


* **Dell & NVIDIA Documentation / Reviews:**
* [Dell XPS 15 9530 Setup and Specifications](https://m.media-amazon.com/images/I/B128v4fC5iL.pdf) — Official specs (130 W USB-C PD, no PCB sensor map).
* [Notebookcheck – Dell XPS 15 9530 RTX 4070 Review](https://www.notebookcheck.net/Dell-XPS-15-9530-RTX-4070-laptop-review-Both-impressive-and-underwhelming.709129.0.html) — Hardware/thermal overview (50 W GPU TGP, 130 W PSU).
* [NVIDIA Developer Forums – PCIe Gen 1 PowerMizer](https://forums.developer.nvidia.com/t/not-getting-full-bandwidth-pcie-transfers/232317) — Driver drops PCIe link to Gen 1 when GPU is idle/low-load.


* **Community Reports & Anecdotes (marked as anecdotes):**
* [Framework Issue #266](https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker/issues/266) — First-hand Linux MSR trace showing `0x64F = 0x10001` during EC-latched 400 MHz `BD PROCHOT`.
* [r/ThrottleStop](https://www.reddit.com/r/ThrottleStop/comments/1np9ovu/how_do_you_change_prochot_in_throttlestop/) & [Framework Community](https://community.frame.work/t/bd-prochot-on-13th-intel-cpu-stuck-at-400mhz/48328) *(anecdotes)* — `BD PROCHOT` firmware-locked on 12th/13th-gen Intel CPUs.
* [r/DellXPS (9530 400 MHz / insulating mesh)](https://www.reddit.com/r/DellXPS/comments/17nac28/considering_buying_the_15_is_cooking_a_real_issue/), [r/DellXPS (9520/9530 VRM mesh)](https://www.reddit.com/r/DellXPS/comments/1hpao06/dell_xps_15_9520_gets_super_slow/), [r/DellXPS (9530 Thermal Management)](https://www.reddit.com/r/DellXPS/comments/1n0nqmw/dell_xps_15_9530_thermal_throttling_management/), [r/DellXPS (9530 thermal mods)](https://www.reddit.com/r/DellXPS/comments/12yw2sl/dell_xps_9530_2023_cinebench_r23_score/) *(anecdotes)* — Owner teardowns linking 400 MHz drops to VRM cooling/insulating mesh under the heatsink.
* [Arch Linux Forums (XPS 15 9520 throttling)](https://bbs.archlinux.org/viewtopic.php?id=282002) *(anecdote)* — `UltraPerformance` still hitting throttling on Linux.
