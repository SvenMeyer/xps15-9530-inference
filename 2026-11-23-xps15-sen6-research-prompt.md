# Research task: Dell XPS 15 9530 forces 400 MHz when a board sensor reaches 65 C

You are researching a hardware/firmware throttling problem. **Research only: do not change the machine or tell anyone to run a write operation without labelling its risk and how to undo it.** Separate verified facts from inference, cite sources, and say when something could not be confirmed.

## System
Dell XPS 15 9530, Intel i7-13700H, NVIDIA RTX 4070 Laptop 8 GB, BIOS 1.34.0 (also seen on 1.13.0), Manjaro Linux, kernel 6.12, NVIDIA driver 615.71, Dell WD22TB4 dock, thermald not installed. The load uses about 32 W CPU + 34 W GPU in Linux balanced mode. Fans are at maximum and were recently cleaned; room is 25 C.

## Observed behavior
- Under sustained mixed CPU+GPU inference, all CPU cores abruptly fall to **400 MHz** for about 45-77 s, and the GPU PCIe link falls from **Gen 4 to Gen 1**. Throughput falls about 70%.
- Linux thermal zone **SEN6** (INT3403-style sensor, same value as `dell_ddv temp8` labelled "Ambient" and `dell_smm temp8`) reports `hot=65.05 C`, `hysteresis=4.00 C`, `critical=70.05 C`. Passive trips read -274 C.
- In 22 measured events, SEN6 was 65.05-66.05 C just before the drop and 61.05-62.05 C when full speed returned. The drop often comes 12-36 s after SEN6 first crosses 65 C.
- CPU package temperature is usually only 85-96 C when it starts, and falls to about 70 C during the stall.
- Linux RAPL limits stay at 115 W, OS max frequency stays 4800 MHz, Linux cooling devices stay at 0. The kernel's package thermal-throttle counter recorded only 18 ms during 165 s at 400 MHz in one run.
- INT3400 reports `current_uuid=INVALID` and `available_uuids=UNKNOWN`. ACPI includes a `DptfTabl` SSDT. A 2,956-byte DPTF `data_vault` is exposed in sysfs.
- Linux exposes SEN6's hot and critical trips as read-only. Only the unset passive trip is root-writable.
- BIOS ThermalManagement was Optimized. Other options: Cool, Quiet, UltraPerformance. Linux balanced is worse than power-saver for this trigger only because it generates more heat; performance mode reaches the limit faster. A BIOS update from 1.13.0 to 1.34.0 changed nothing.

## Questions, in priority order
1. **What is SEN6 physically** on the XPS 15 9530 (or its closest board siblings)? VRM, charger, memory, SSD, skin, or something else? What does exceeding 65 C risk?
2. **What mechanism forces 400 MHz and PCIe Gen 1?** Embedded-controller PROCHOT, BD PROCHOT, a DPTF/DTT policy, a Dell SMM action, or something else? Give exact non-destructive Linux checks, including MSRs (0x19C, 0x1B1, 0x1FC, 0x64F), `turbostat` columns, and how to interpret them.
3. **Can the 65 C limit be raised or the response softened safely?** Evaluate BIOS ThermalManagement modes, Dell Command | Configure, Dell WMI/SMM, DPTF data vault (GDDV), ACPI SSDT override through initrd, and EC settings. For each: does it actually affect the EC decision, or only what Linux displays?
4. **Is Linux missing the policy Windows uses?** Would `thermald`, `dptfxtract`, or the INT3400 UUID/_OSC handshake provide gradual throttling on this model? Does Windows with Intel DTT avoid this cliff on the same laptop?
5. **Can BD PROCHOT safely be disabled** on this platform (MSR 0x1FC bit 0)? Does Raptor Lake or this firmware honor it? What protections would remain, and what could be damaged?
6. **Known reports and fixes** for XPS 15 9530/9520, XPS 17 9730/9720, and Precision siblings: same sudden 400 MHz behavior, Dell advisories, thermal pad/paste/VRM repairs, or EC bugs.
7. **Could this indicate a hardware fault**, such as a failed thermal pad, poor VRM contact, or a miscalibrated sensor? How would we test that?

## Required output
1. A short conclusion and confidence level.
2. Ranked options: root-cause fix first, then workarounds. For each give exact steps, expected effect, risk, reversibility, and sources.
3. A safe diagnostic plan: read-only commands first, then any reversible test.
4. Explicit "do not do this" items.
5. Links for every important claim. Prefer Intel documentation, Dell documentation, Linux kernel source, thermald source, and first-hand measurements. Mark forum anecdotes as anecdotes.
