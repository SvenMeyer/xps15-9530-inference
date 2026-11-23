# XPS 15 9530 SEN6 brake: research result (Opus 5.5)

**Last updated:** 2026-11-24. New results go in the additions log at the end.
**Status:** I changed nothing on the machine. The register and ACPI results come from sudo captures the user ran. A separate Neon session also ran `thermald`, which changed firmware state (section 4).
**Answers:** `2026-11-23-xps15-sen6-research-prompt.md`. **Compared with:** the Grok and Neon result files beside this one.

## 1. Conclusion

**Most likely:** when the charger sensor SEN6 reaches 65 C, firmware applies a CPU package power limit from outside the OS and releases it at 61 C. **It is not PROCHOT**, which was this report's earlier leading theory.
**Confidence:** high that it is a power limit and not PROCHOT. Medium that the EC applies it over PECI, because the OS cannot observe that path.

1. **SEN6 is Dell's "Charger Temperature Sensor(QE10)".** The ACPI table names it and reads it from EC channel 7.
2. **The registers rule out PROCHOT.** The PL1 limit bit (0x64F bit 10) was set in all 80 samples at or below 450 MHz. PROCHOT status and log stayed 0 in all 505 samples, and the log was also 0 in a separate snapshot taken after two earlier brake traces in the same boot. The OS-visible limits stayed at 115 W and the platform PL1 is disabled.
3. **The `_OSC` handshake is one-way.** It writes 1 to EC register 0x32, and no ACPI code writes 0. Neon's `thermald --adaptive` test triggered it at about 00:54 on 2026-11-24, so the flag has probably stayed set since. The OS cannot read it directly.
4. **That flag may switch the 65 C brake off.** After the handshake, SEN6 stayed at 65-66 C for 60 s at full speed until the run ended. In the 24 clean-state cases the brake always came within 47 s. This is one event, so it is a hypothesis. **If true, the machine currently has no 65 C brake and should not run heavy loads until it has been fully powered off.**
5. **A soft CPU cap avoids the brake.** A thermald policy that caps CPU power at 22 W from SEN6 63 C ran at 24.0 and 25.5 t/s in its last two rounds, against about 17-20 t/s unmitigated. SEN6 peaked at 64.05 C. This is one 5.5-minute run, after the handshake, with about 1 C of margin.

## 2. Evidence

### Verified on this machine, without root

- SEN6 is an EC-owned ACPI device: `\_SB_.PC00.LPCB.ECDV.SEN6`.
- The 2,956-byte data vault decompresses to 82,639 bytes and 217 keys.

| Sensor | Live hot / crit (C) | Vault hot / crit (C) | Match |
|---|---|---|---|
| **SEN6** | **65 / 70** | **70 / 75** | **No** |
| SEN4 | 65 / 70 | 65 / 70 | Yes |
| SEN1 | 67 / 72 | 67 / 72 | Yes |
| SEN2 | 68 / 73 | 68 / 73 | Yes |
| SEN3 | 58 / 63 | 58 / 63 | Yes, but hysteresis is 0 live and 2 in the vault |
| SEN5 | 90 / 95 | 90 / 95 | Yes |
| SEN7 | 95 / 97 | 95 / 97 | Yes |
| SEN9 | 94 / 99 | 94 / 99 | Yes |
| SKIN | 82 / 87 | 82 / 87 | Yes |

- Dell's table for Optimized mode (`op`, selected by `Oem0==0`) limits PL1 to 45 W above SKIN 46 C and to 15 W above SEN5 62 C. SEN6 has a row only at 90 C, so **Dell's software policy does not act on SEN6 near 65 C**.
- That table sets PL1 76 W and PL2 115 W. Linux currently runs PL1 at 115 W.
- BIOS 1.34.0 reads `ThermalManagement=Optimized`, with Turbo, SpeedStep, C-states and all cores enabled and PeakShift off. The update did not reset these settings.
- All 22 brakes in the traces began at SEN6 65-66 C. All 21 observed releases were at 61 C. No other sensor has a release band that narrow.
- During brakes the GPU link was at Gen 1 in 96.9% of generating seconds, against 0.4% otherwise. In 21 of 22 brakes it dropped in the same second as the CPU or later.
- During brakes the GPU core clock did not fall (median 1830 MHz, against 1440 MHz normally), while GPU power fell from 34.5 W to 25.4 W. The GPU's reported limit flag moved from `0x4` to `0x400`. I have not verified what `0x400` means.

### Verified from sudo captures (2026-11-24)

- `SEN6` in SSDT4: `_STR` is "Charger Temperature Sensor(QE10)", `_TMP` reads EC channel 7, and `_HOT`/`_CRT` return the constants 65 and 70 C. My ACPI dump and Neon's are byte-identical for DSDT, SSDT4 and SSDT12.
- Static registers at 00:11: 0x64F log bits 1, 8, 10, 11, 12 (PROCHOT log clear, PL1 log set), BD PROCHOT enabled (0x1FC bit 0), PL1 and PL2 115 W and unlocked (0x610), platform PL1 disabled and platform PL2 302 W (0x65C).
- Mid-brake `turbostat`, one 1 s sample: 400 MHz, package 9.18 W, RAPL throttle counter 101.89%, 0 core throttle events, 0 SMIs.
- `_OSC` with UUID `b23ba85d-...` sets `DDDR=1` and calls `DPST(1)`, which writes EC register 0x32. Stopping thermald makes the kernel call `_OSC` with no capabilities. That restores the trip values but leaves `DDDR` and the EC register alone.

### Inferred from traces, not proven

- Fit over 10 runs: **SEN6 = 46.2 + 0.19 x CPU W + 0.41 x GPU W**, about 60 s lag, R2 = 0.87. CPU and GPU power move together across arms, so the split is approximate.
- At 22 W CPU and 34 W GPU the fit predicts SEN6 of 64.4 C, and the 22 W test settled at 64.05 C. About 18 W would add only about 0.8 C of margin.
- The 12-36 s delay may be a second condition. All 22 brakes occurred with SEN6 >= 65 and SKIN >= 59, but SKIN sits near 59 for long periods, so this is weak evidence.
- The GPU link drop appears to follow the CPU brake rather than cause it.

### Unknown

- Whether the EC flag really disables the 65 C brake, and whether a full shutdown clears it.
- Which firmware path applies the power limit, and its actual value. The 9.18 W is what the CPU drew at its 400 MHz floor, so the limit could be lower.
- What actually writes the PCIe root port's target speed during a brake.
- What exceeding 65 C risks on the charger circuit. Dell does not document it.
- How Windows behaves on this laptop. I found no measurement.

## 3. Answers to the research questions

1. **What is SEN6?** Dell's ACPI table calls it the charger temperature sensor (QE10). Its exact board position and the risk above 65 C are not published.
2. **What forces 400 MHz?** A package power limit, shown by 0x64F bit 10 and the RAPL throttle counter. PROCHOT did not fire. The limit does not come from 0x610, the MMIO limit or the platform limit, so an EC limit over PECI is the best remaining explanation.
3. **Can the limit be raised safely?** No supported way was found. The 65 and 70 C constants are only returned to the OS, so an SSDT override would not reach the EC. The `_OSC` flag may relax the brake, but using it that way would leave the charger without that protection.
4. **Is Linux missing the Windows policy?** Yes. `thermald --adaptive` applies Dell's table and avoided the brake, but capped the CPU at 15 W and ran its last round at 17.2 t/s. A policy aimed at SEN6 did better.
5. **Can BD PROCHOT be disabled safely?** Do not do this. PROCHOT does not fire during this brake, so clearing it should not help and would remove real protection.
6. **Known reports.** I found no report or Dell advisory specific to the 9530. The closest is an XPS 15 9520 Arch thread (anecdote): 400 MHz for about 5 minutes after sustained heat, with no confirmed cause.
7. **Hardware fault?** Not shown. The VRM sensor peaked at 75 C against a 94 C limit and the CPU over-temperature sensor at 71 C against 95 C. The repeatable 65/61 C cycle fits firmware logic. The cold-start check in section 6 can still detect a sensor offset.

## 4. Comparison with Grok's report

Both Grok and my first pass named external PROCHOT#, and the register captures have since ruled it out. **Still agreed:** SEN6's board position is unpublished, read-only checks come first, the limit should not be raised, and the 24-run suite should wait. I also adopt Grok's reminder to confirm the engine log shows about 12.7 GB/s before trusting a benchmark, because of the separate stuck-Gen-1 issue.

| Grok's claim | Check | Result |
|---|---|---|
| SEN6 type 0x44 is Ambient, sometimes SKIN | Kernel `dell-wmi-ddv.c` | **Correct**, but the label is shared by six sensors |
| Balanced + 5 P-cores stays under the SEN6 trip | Evidence table | **Wrong.** That arm had 3 brakes and 143 s braked. Only the power-saver arms avoided it |
| `turbostat` can show PROCHOT flags | Kernel 6.12 source | **Not on this CPU.** Its Raptor Lake profile does not enable the perf-limit decode |
| Install `msr-tools` and `turbostat` | Kernel config | **Not needed.** The MSR driver is built in, and the read-only logger uses it directly |
| thermald may do nothing because the UUID is INVALID | thermald 2.5.13 source | **Unlikely.** `UNKNOWN` is the case where it writes the passive UUID |
| thermald is daemon-only and reversed by stopping it | thermald and kernel source | **Understated.** It triggers a firmware `_OSC` call, and its exit path does not write the UUID. Reboot after a trial |
| Cool or Quiet gives an earlier fan ramp | Traces | **Unlikely to help that way.** Fans are already at about 5,900 and 5,600 RPM |
| Short BD PROCHOT test after diagnostics | Kernel 6.12 source | **I advise against it.** Linux would not act on a SEN6 critical trip |
| VRM, charger or chassis is the leading location | Power fit | **Unproven.** The GPU-weighted response argues against a CPU-only VRM, but not against a shared or GPU-side part |

### Neon's report

Neon's captures are the most useful evidence so far. Its main findings hold, but several "100% proven" labels go further than the data.

| Neon's claim | Check | Result |
|---|---|---|
| SEN6 is the charger sensor | SSDT4 | **Correct** |
| PROCHOT never fired | 505 samples and a separate snapshot | **Correct** |
| The brake is a power limit | 0x64F bit 10, RAPL throttle counter | **Correct** |
| It is an EC PECI limit of about 9 W | PECI is not visible, and 9.18 W is the draw at the frequency floor | **Plausible, value unknown** |
| The root port's target speed restores in 0 s | One root-port snapshot; the 1 Hz log reads only the GPU side | **Not measured** |
| 22 W policy gives 26.28 t/s with no brake | Recomputed from the JSONL | **Correct**, but rounds 1-2 ran before the cap. Steady rounds were 24.0 and 25.5 |
| The policy works independently of `DPST(1)` | Its only successful run came after the handshake | **Untested** |
| The policy only moves the MMIO limit | Telemetry also shows MSR PL1 briefly at 15-39 W | **Incomplete**, another thermald loop also acts |
| No `/sys` or MSR value was modified | thermald wrote RAPL limits and triggered `_OSC`; three packages were installed | **Wrong for the test phase** |
| Ctrl-C undoes the test | RAPL is restored, but no ACPI code clears the EC flag | **Incomplete** |
| Charger parts reach 90-115 C; power-off at 70 C | No source or measurement | **Unsupported** |

## 5. Ranked options

| Rank | Option | Expected effect | Risk | Undo |
|---|---|---|---|---|
| 1 | Full power-off, then one unmitigated trace | Shows whether the 65 C brake is back | Very low | Nothing to undo |
| 2 | SEN6 thermald policy on that clean boot, with a soak of at least 30 min | About 24-25 t/s if it holds without the handshake | Low: changes CPU power limits while running | Ctrl+C restores them |
| 3 | Fixed PL1 of 18-22 W with no daemon | Simpler, but gives up the early full-power phase | Low | Write 115 W back, or reboot |
| 4 | Active cooling under the laptop, or another 130 W power source if one is available | May lower SEN6 and allow a higher cap | Very low | Remove it |
| 5 | Dell service, only if the cold-start check shows a sensor offset | Fixes a real fault if there is one | Warranty and repair process | Not applicable |

Write steps, **not run by me and not to be run until the user decides**:

    # Option 2: foreground only. Overwrites the previous sen6-thermald-custom log and telemetry
    sudo ~/Downloads/AI-Runtime/sen6-test-thermald.sh custom
    # Ctrl+C stops thermald and restores the saved limits

    # Option 3: both limits reset at reboot
    echo 20000000 | sudo tee /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
    echo 20000000 | sudo tee /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
    # Undo: write 115000000 to the same two files

## 6. Safe diagnostic plan

1. **Shut down fully rather than restarting.** Avoid heavy loads before this.
2. **Check that the brake is back.** Run `strata-throttle-trace.sh`, optionally with `msr-watch.py` in a second terminal. A brake at SEN6 65 C means the flag was cleared. No brake means it survived the shutdown, and the laptop should not run long heavy loads until that is resolved.
3. **Test the policy on that clean boot** (option 2), and do not run `--adaptive` first. A pass means no brake and SEN6 below 65 C for the whole soak.
4. **Cold-start check:** leave the laptop off for an hour, boot, and read all zones at once. A SEN6 several degrees above its neighbours suggests a sensor offset.

`msr-watch.py` has been tested only against fake register files. Its verdict will read "neither" for this brake, because it tests only for PROCHOT and CPU thermal limits. Use its logged 0x64F values.

## 7. Do not do this

- Do not run long heavy loads on the current boot, because the 65 C brake may be off.
- Do not run `thermald --adaptive` again, or anything else that calls `_OSC`, before the clean-boot test.
- Do not enable `thermald.service` until the policy passes a soak on a clean boot.
- Do not clear BD PROCHOT (MSR 0x1FC bit 0). It is not the mechanism.
- Do not write EC registers or use EC-access tools.
- Do not override the SSDT or edit firmware to raise the SEN6 trip.
- Do not treat SEN6's Linux critical trip as a safety net. It only logs.
- Do not run a plain `fwupdmgr update`, because it would also apply the deliberately deferred dock and Secure Boot updates.
- Do not resume the 24-run suite until a setting has passed the clean-boot soak.

## 8. Sources

Primary:

- Intel 12th Gen Core Datasheet Vol. 1, doc 655258 rev. 011, sections 5.1.3.3-5.1.3.9: https://edc.intel.com/output/DownloadPdfDocument?id=8297. The 13th Gen copy (743844) returned 404, so the wording is from the previous generation.
- Linux v6.12 INT340x zone: https://github.com/torvalds/linux/blob/v6.12/drivers/thermal/intel/int340x_thermal/int340x_thermal_zone.c
- Linux v6.12 INT3400 and `_OSC`: https://github.com/torvalds/linux/blob/v6.12/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
- Linux v6.12 turbostat: https://github.com/torvalds/linux/blob/v6.12/tools/power/x86/turbostat/turbostat.c
- Linux v6.12 Dell DDV driver: https://github.com/torvalds/linux/blob/v6.12/drivers/platform/x86/dell/dell-wmi-ddv.c
- thermald 2.5.13 UUID handling: https://github.com/intel/thermal_daemon/blob/v2.5.13/src/thd_int3400.cpp
- thermald 2.5.13 adaptive engine: https://github.com/intel/thermal_daemon/blob/v2.5.13/src/thd_engine_adaptive.cpp
- thermald 2.5.13 vault parser: https://github.com/intel/thermal_daemon/blob/v2.5.13/src/thd_gddv.cpp
- GDDV export patch: https://lore.kernel.org/lkml/20200414020953.255364-1-matthewgarrett@google.com/
- IDSP-in-GDDV discussion: https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2005.2/02710.html
- Intel SDM MSR 19CH, through a mirror and search summary: https://xem.github.io/minix86/manual/intel-x86-and-64-manual-vol3/o_fe12b1e2a880e0ce-491.html

Captures from this machine (in this repo unless noted):

- `sen6-diag-idle.txt`, `sen6-diag-brake.txt`, `sen6-diag-pcie-brake.txt`, `sen6-thermald-*-telemetry.txt`, `sen6-thermald-*-strata.jsonl`
- `xps15-sen6-research/sen6-diag-turbostat-redacted.txt` (disk UUIDs removed) and `xps15-sen6-research/xps15-sen6-check-20261124-0011/`
- Decompiled ACPI tables are not committed. Regenerate them with `sen6-diag-readonly.sh`.

Anecdotes:

- XPS 15 9520 thread, read in full: https://bbs.archlinux.org/viewtopic.php?id=282002
- 13th Gen BD PROCHOT lock, search snippet only (direct read returned 403): https://www.techpowerup.com/forums/threads/prochot-locked-on-13th-gen.303977/latest
- Latitude thermald reports, search snippet only: https://www.dell.com/community/Latitude/Latitude-5420-7420-7520-CPU-Throttling-Issue-on-Linux/m-p/8129794

## 9. Additions log

- **2026-11-23:** first pass. Decoded the data vault, replayed the 22 brakes against Dell's policy, and wrote the read-only logger and static check.
- **2026-11-24:** compared with Grok's report and checked its claims. Found the thermald `_OSC` handshake, confirmed the packaged 2.5.13 handles this CPU and vault, and added the GPU-link timing.
- **2026-11-24 (later):** read the user's static check, then checked Neon's report and walkthrough against the raw captures. PROCHOT is ruled out, SEN6 is the charger sensor, and the `_OSC` flag is one-way and may disable the brake. The BIOS settings are unchanged. `msr-watch.py` was not run, because Neon's capture covers the same registers.
- **Pending:** full power-off and brake check, clean-boot policy soak, cold-start check.
