# XPS 15 9530: 400 MHz firmware brake under Strata load (evidence, 2026-11-23)

**Status:** root cause not fixed. The trigger is strongly linked to board sensor SEN6. The exact mechanism is unproven.
**Start here in a new session:** read this file, then `2026-11-23-xps15-sen6-research-prompt.md`. Do not resume the 24-run suite until this is settled.

## System
- Dell XPS 15 9530, i7-13700H (6P + 8E), RTX 4070 Laptop 8 GB, 125 GB RAM, Manjaro, kernel 6.12.112, NVIDIA 615.71.09.
- BIOS updated 2026-11-23 from 1.13.0 to **1.34.0** (08/27/2026). Downgrade is not allowed.
- Power through Dell WD22TB4 Thunderbolt dock. Room about 25 C, fans cleaned about two days before.
- Strata 0.2.20 / engine 0.1.66 active. Engine 0.1.57 remains installed.
- Benchmark launch: GSQ IQ3_S, 64k, DFlash2, `STRATA_ROUTE_TAIL_SKIP=0`, `STRATA_ROUTE_PRIOR=1.5`, `conversation-spill-mib=0`.
- Current boot: gpu-unlock entry. Power profile balanced. No lasting power, fan or thermal setting was changed by these tests.

## What happens
During token generation, all CPU cores drop to 400 MHz for about 45-77 s, the GPU link falls from PCIe Gen 4 to Gen 1, and decode falls from about 27-30 t/s to about 7-8 t/s. Tokens keep flowing, Strata stays busy, and a separate probe loop on a spare core runs about 6x slower. This is not waiting on tests or I/O.

## Strongest evidence: SEN6
- The firmware-reported thermal zone **SEN6** has `hot = 65.05 C` and `hysteresis = 4.00 C`, so it should release at **61.05 C**.
- Across 22 brake episodes in the three traces, SEN6 read 65.05-66.05 C just before the drop and 61.05-62.05 C when it ended.
- SEN6 is the same reading as `dell_ddv temp8` (label "Ambient") and `dell_smm temp8`. Its physical location is unknown.
- Caveat: the drop usually comes 12-36 s **after** SEN6 first crosses 65 C, and two crossings had no drop within 40 s. A dwell timer or second condition may be involved.

Firmware trip points read from Linux (C):

| Sensor | hot | hysteresis | hot minus hysteresis | critical |
|---|---:|---:|---:|---:|
| SEN1 | 67.05 | 4.00 | 63.05 | 72.05 |
| SEN2 | 68.05 | 4.00 | 64.05 | 73.05 |
| SEN3 | 58.05 | 0.00 | 58.05 | 63.05 |
| SEN4 | 65.05 | 4.00 | 61.05 | 70.05 |
| SEN5 | 90.05 | 4.00 | 86.05 | 95.05 |
| SEN6 (trigger) | 65.05 | 4.00 | 61.05 | 70.05 |
| SEN7 | 95.05 | 4.00 | 91.05 | 97.05 |
| SEN8 | none | none | none | none |
| SEN9 | 94.05 | 4.00 | 90.05 | 99.05 |
| SKIN | 82.05 | 4.00 | 78.05 | 87.05 |

All passive trip points on these zones read -274 C (unset). SEN4 has the same 65.05 C limit but read only 54-55 C at the drops, so it is not the trigger.

Linux exposes SEN6's `hot` and `critical` limits and hysteresis as **read-only**. Only the unset passive trip is root-writable, so there is no normal Linux setting that raises the 65 C limit.

## Per-run results

| Run | Arm | Overall t/s | Brake events | Brake seconds | SEN6 at start | SEN6 at release | CPU's own package-throttle ms |
|---|---|---:|---:|---:|---:|---:|---:|
| BIOS 1.34.0, steady A/B | saver | 12.8 | 0 | 0 | - | - | 0 |
| BIOS 1.34.0, steady A/B | p5 | 21.5 | 3 | 143 | 65-65 | 61-61 | 51873 |
| BIOS 1.34.0, steady A/B | saverp5 | 13.9 | 0 | 0 | - | - | 0 |
| BIOS 1.34.0, steady A/B | balanced | 19.6 | 3 | 169 | 65-65 | 61-62 | 2396 |
| BIOS 1.13.0, trace | balanced | 24.3 | 1 | 54 | 65-65 | 61-61 | 759 |
| BIOS 1.13.0, trace | performance | 15.7 | 4 | 242 | 65-66 | 61-61 | 50377 |
| BIOS 1.13.0, trace | balanced | 17.1 | 3 | 198 | 65-65 | 61-61 | 18 |
| BIOS 1.34.0, trace | balanced | 24.1 | 1 | 55 | 65-65 | 61-61 | 260 |
| BIOS 1.34.0, trace | performance | 15.8 | 4 | 249 | 65-66 | 61-61 | 49419 |
| BIOS 1.34.0, trace | balanced | 17.4 | 3 | 184 | 65-65 | 61-61 | 20 |

Saver arms are the `power-saver` profile (ACPI `quiet`). `p5` is 5 P-core workers. Each arm is one start, so differences of a few percent are not proven.

## What we ruled out or learned
- **Strata version:** not the cause. 0.2.20 and 0.2.11 tie (28.5 vs 29.1 t/s unthrottled, 3 alternating starts each). Old logs show the same pattern since at least 2026-10-28.
- **Local Strata patches:** none existed. Both engines match their signed manifests.
- **BIOS version:** 1.13.0 and 1.34.0 behave the same.
- **BIOS settings on 1.13.0:** ThermalManagement=Optimized, Turbo, SpeedStep, C-states and all cores on, PeakShift off. **Not re-read after the 1.34.0 update.**
- **Linux power limits:** RAPL stays 115 W, OS max frequency stays 4800 MHz, Linux cooling devices stay at 0.
- **CPU's own thermal limit:** not the main trigger. In one balanced run there were 165 s at 400 MHz but only 18 ms of counted package thermal throttling. Performance mode does also hit the CPU's 100 C limit.
- **Dock or charger power:** unlikely. CPU + GPU drew 63-73 W just before drops. Not directly tested, and 1 s averages can hide short spikes.
- **Performance mode:** worse. SEN6 rises 7.5-9.4 C/min vs 4.5-4.9 C/min in balanced.
- **Power-saver:** avoids the brake (SEN6 56-58 C) but runs only 12.8-13.9 t/s.
- **Best setting so far:** balanced + 5 P-cores, 21.5 vs 19.6 t/s, one start each. It runs the CPU hotter and logged about 52 s of the CPU's own thermal throttling.
- **Deferred by the user:** a CPU power cap between power-saver and balanced. It is a workaround and does not address the root cause.

## Unproven hypotheses
1. The embedded controller asserts external PROCHOT when SEN6 reaches its hot trip. This fits the 400 MHz floor and low internal throttle count, but MSRs have not been read.
2. Linux has no active DPTF/DTT policy: `thermald` is not installed, INT3400 reports `current_uuid=INVALID`, `available_uuids=UNKNOWN`, and passive trips are unset. Windows may throttle gradually before the hard limit.
3. SEN6 may protect a VRM, charger, memory or chassis area. **Raising or bypassing its limit could remove real protection until this is known.**

## Separate issue
On 2026-11-23 from about 17:52 the GPU link stayed at PCIe Gen 1 even under load until reboot. No AER or replay errors were logged and the trigger is unknown. Check that the engine log says about 12.7 GB/s for the card link before trusting any benchmark.

## Not done yet (needs sudo)
- Re-read BIOS settings on 1.34.0.
- During a stall, read MSRs 0x19C, 0x1B1, 0x1FC and 0x64F, or use `turbostat`, to prove which limit fires. `msr-tools` and `turbostat` are not installed.
- Dump and decompile ACPI tables to identify SEN6. The kernel log shows a `DptfTabl` SSDT.
- Try `thermald` (available in Manjaro `extra`, 2.5.13).

No sudo needed: inspect the 2,956-byte DPTF data vault at `/sys/bus/platform/devices/INTC10A0:00/data_vault`, which may contain Dell's thermal policy.
- Pending fwupd updates are dock firmware and Secure Boot keys/dbx. They were deliberately not applied.

## Files
- Traces: `strata-throttle-trace-20261123-2004-*` (BIOS 1.13.0), `strata-throttle-trace-20261123-2222-*` (BIOS 1.34.0), `strata-steady-ab-20261123-2244-*`.
- Scripts: `strata-throttle-trace.sh`, `strata-throttle-trace.py`, `strata-steady-ab.sh`, `strata-version-ab.sh`.
- Engine comparison: `strata-version-ab-20261123-1902.txt`. BIOS 1.13.0 output: `BIOS-Check_1.13.0.txt`.
