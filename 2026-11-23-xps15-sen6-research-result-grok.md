# SEN6 research report - grok.com (grok-4.7)

**Short conclusion (confidence: medium-high on mechanism, medium on exact sensor location)**  
SEN6 is the Ambient-type board sensor reported by `dell_ddv` temp8 / `dell_smm` temp8 (type code 0x44, sometimes labelled Ambient/SKIN in Dell DDV). On the XPS 15 9530 (and 9520 siblings) it is the trip that correlates with the hard 400 MHz + PCIe Gen1 cliff. The most likely mechanism is the embedded controller asserting external PROCHOT (BD PROCHOT) when SEN6 reaches its firmware hot limit of 65.05 °C (releases ~61 °C). This matches the observed 400 MHz floor, near-zero kernel package-throttle counter, and simultaneous GPU link drop. Linux is not running the full DPTF/DTT policy stack that Windows uses (INT3400 `current_uuid=INVALID`, `available_uuids=UNKNOWN`, no `thermald`).  

Exact physical location of SEN6 is not published in Dell service manuals or public sensor maps. Older XPS 15 generations have well-documented VRM/MOSFET thermal issues that produce the same external-PROCHOT behaviour; a VRM, charger, or nearby chassis ambient is the leading hypothesis. Exceeding 65 °C risks whatever that sensor protects (VRM junction, board area, or skin). Raising the limit or ignoring PROCHOT removes that protection.

**Ranked options**

1. **Root-cause diagnostics first (read-only)** — Confirm mechanism before any change.  
   Expected: prove external PROCHOT vs CPU thermal/RAPL.  
   Risk: none. Reversible: N/A.  
   Sources: Intel MSR docs, kernel `turbostat`/`msr-tools`.

2. **Keep power-saver or balanced + limited P-cores / modest power cap** (already observed to stay under SEN6).  
   Expected: avoid the cliff (12–14 t/s or ~21 t/s with 5 P-cores).  
   Risk: low. Reversible: change power profile.  
   Sources: your traces.

3. **Install and test `thermald` (Manjaro extra) with adaptive/GDDV if available**.  
   Expected: possible gradual throttling if DPTF tables are usable; may do nothing because UUID is INVALID.  
   Risk: low (daemon only). Reversible: stop/disable.  
   Sources: Intel thermal_daemon, kernel DPTF sysfs docs.

4. **BIOS ThermalManagement = Cool or Quiet** (re-read after 1.34.0).  
   Expected: earlier fan ramp / lower sustained power; may delay SEN6 trip.  
   Risk: low. Reversible: set back to Optimized.  
   Sources: Dell BIOS / Power Manager docs (Optimized/Cool/Quiet/UltraPerformance).

5. **Temporary BD PROCHOT disable (MSR 0x1FC bit 0) only as a controlled test**.  
   Expected: if it is the mechanism, clocks stay high while SEN6 is >65 °C.  
   Risk: **high** — removes external protection; VRM or board damage possible if SEN6 is a real thermal limit. Reversible: write bit back or reboot (firmware may re-assert). On some Raptor Lake platforms the bit can be locked.  
   Sources: Intel MSR_POWER_CTL, multiple BD-PROCHOT Linux write-ups.

6. **Hardware: inspect/repaste + VRM thermal pads** (only if diagnostics show high SEN6 with clean fans and modest power).  
   Expected: lower SEN6 under the same load.  
   Risk: medium (disassembly). Reversible: yes if done carefully.  
   Sources: XPS 95xx VRM pad mod reports (anecdotes + repair guides).

No safe software method was found that raises the 65 °C SEN6 hot trip itself. Linux exposes the hot/critical values as read-only; only the unset passive trip is writable. Dell Command | Configure / WMI may change ThermalManagement profile but not this EC trip. ACPI SSDT override or data_vault edits are unproven on this model and high-risk.

**Safe diagnostic plan (read-only first)**

1. During a known stall:  
   - `sudo rdmsr -a 0x19C` (IA32_THERM_STATUS) — check bit 2 (PROCHOT/FORCEPR) and bit 0 (thermal status).  
   - `sudo rdmsr -a 0x1B1` (package therm status) — same bits.  
   - `sudo rdmsr -a 0x1FC` (MSR_POWER_CTL) — bit 0 = BD PROCHOT enable.  
   - `sudo rdmsr -a 0x64F` (CORE_PERF_LIMIT_REASONS) if present.  
   - `sudo turbostat --interval 1 --show PkgWatt,CorWatt,Avg_MHz,PkgTmp,CoreTmp,CoreThr,Pkg%pc2,Pkg%pc6` (or `--debug`). Look for PROCHOT flags with package <<100 °C and RAPL limits unchanged.  
   Install `msr-tools` + `turbostat` if missing.

2. Confirm sensor:  
   `cat /sys/class/thermal/thermal_zone*/type` and trip points; compare SEN6 with `dell_smm`/`dell_ddv` temp8.  
   Dump `/sys/bus/platform/devices/INTC10A0:00/data_vault` (or INT3400) for later offline decoding (thermald tools).

3. Optional reversible: boot with `thermald --adaptive` (or default) and re-test the same Strata load. Stop the daemon to reverse.

4. Only after the above: short test of clearing 0x1FC bit 0 while monitoring SEN6 and package temps. Re-set the bit immediately.

**Explicit do-not**

- Do not permanently clear BD PROCHOT or raise SEN6 limits until the physical sensor and its protection role are known.  
- Do not force higher power limits or UltraPerformance while SEN6 is the active trip.  
- Do not apply unverified ACPI overrides, EC firmware mods, or data_vault binary edits.  
- Do not ignore the separate Gen1 PCIe link-stuck issue (check engine log bandwidth ~12.7 GB/s before trusting benchmarks).  
- Do not resume the 24-run suite until the mechanism is confirmed and a stable workaround chosen.

**Key sources**  
- Kernel `dell-smm-hwmon` / `dell-wmi-ddv` (sensor type 0x44 = Ambient): kernel docs.  
- Intel DPTF sysfs (`data_vault`, UUIDs, INT3400): kernel.org intel_dptf.html.  
- MSR 0x1FC bit 0, 0x19C/0x1B1 PROCHOT bits: Intel SDM + multiple Linux BD-PROCHOT write-ups.  
- XPS 15 VRM thermal history: UltrabookReview and repair guides (anecdotes for older chassis; same external-PROCHOT pattern).  
- thermald adaptive/GDDV: intel/thermal_daemon.  

No public Dell advisory or exact SEN6 map for the 9530 was found. The correlation in your 22 events is the strongest evidence available.
