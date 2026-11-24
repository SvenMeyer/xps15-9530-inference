# Handover: XPS 15 9530 SEN6 throttle (Opus 5.5)

**Written:** 2026-11-24 02:05 AEDT. **Folder:** `/home/sum/Downloads/AI-Runtime`. **Branch:** `xps15-sen6-research`.

## 1. Start here

**The next action belongs to the user: shut the laptop down fully, then run the brake check in section 5.** None of section 5 has been run yet.

Until that is done, treat the 65 C brake as possibly off and run no heavy load. Ask the user whether the full shutdown has happened. `uptime -s` later than `2026-11-23 22:19:17` shows a new boot, but it cannot tell a shutdown from a restart.

Read in this order:

1. This file.
2. `2026-11-23-xps15-sen6-research-result-opus-5.5.md`, sections 1 and 6. This is the canonical report, and **new results go in its section 9 additions log**.
3. `2026-11-23-xps15-sen6-throttle-evidence.md` and the Neon report, only if details are needed.

## 2. Goal and rules

The goal is to remove the 400 MHz brake that costs up to half of Strata generation time, without weakening the protection it provides.

- **Research prompt rule:** do not change the machine, or tell anyone to run a write operation, without labelling its risk and how to undo it. Separate verified facts from inference.
- **The user runs every sudo command.** Give the exact commands and wait for the output.
- Commit or push only when the user asks. The GitHub repo is **public**.
- Strata tests use the IQ3_S quant.
- Do not resume the 24-run Strata 0.2.20 suite until a setting has passed the clean-boot soak.

## 3. Machine state at handover

| Item | State |
|---|---|
| Boot | Since 2026-11-23 22:19:17, **not yet shut down** |
| EC flag (register 0x32) | **Probably still 1** since `thermald --adaptive` ran at about 00:54. Not directly readable |
| `thermald` | Package installed, service disabled and inactive, no `/etc/thermald/thermal-conf.xml`, no systemd override |
| CPU PL1 | 115 W on both `intel-rapl:0` and `intel-rapl-mmio:0` |
| Profile, Strata | `balanced`, Strata not running |
| Hardware and software | XPS 15 9530, i7-13700H, RTX 4070 Laptop 8 GB, BIOS 1.34.0, kernel 6.12.112, NVIDIA 615.71, WD22TB4 dock, Strata 0.2.20 |
| Physical setup | USB-C power through the dock only, laptop raised about 2 cm |
| `sen6-test-thermald.sh` | **Still has the 720 s limit.** The `sed` in section 5 has not been applied |

## 4. What is known

**Verified from registers, ACPI or recomputed data:**

- SEN6 is Dell's "Charger Temperature Sensor(QE10)", read from EC channel 7. Its ACPI hot and critical trips are 65 and 70 C. Dell's data vault lists 70 and 75 C.
- The brake starts at SEN6 65-66 C and ends at 61 C (22 brakes across the traces).
- It is a **package power limit, not PROCHOT**. 0x64F bit 10 was set in all 80 samples at or below 450 MHz. PROCHOT status and log were 0 in all 505 samples.
- The OS-visible limits stayed at 115 W during the brake, and the platform PL1 is disabled.
- ACPI `_OSC` calls `DPST(1)`, which writes EC register 0x32. **No ACPI code writes it back to 0.** Stopping thermald restores the trip values only.
- `thermald --adaptive` triggers `_OSC`, avoids the brake, and caps the CPU at 15 W (17.24 t/s in its last round).
- Custom mode (`--config-file`, no `--adaptive`) does **not** trigger `_OSC`. Its log has no "Set Default UUID" line, and all 516 telemetry samples read `INVALID`.
- The custom policy (SEN6 63 C caps CPU at 22 W) ran rounds 3 and 4 at **24.01 and 25.49 t/s**, with SEN6 peaking at 64.05 C. Unmitigated runs give 17.4-19.6 t/s.
- BIOS settings survived the update (`ThermalManagement=Optimized`, Turbo, C-states and all cores on).

**Inferred, not proven:**

- The EC applies the limit over PECI. The OS cannot see that path. The 9.18 W reading is the draw at the 400 MHz floor, so the limit's value is unknown.
- **The EC flag may disable the 65 C brake.** After the handshake, SEN6 held 65-66 C for 60 s at full speed until the run ended, while 24 clean-state cases all braked within 47 s. This is one event.
- Power fit: SEN6 = 46.2 + 0.19 x CPU W + 0.41 x GPU W (R2 0.87, about 60 s lag). It predicts 64.4 C for the 22 W run, against 64.05 C measured.

**Unknown:**

- Whether a full shutdown clears the EC flag. The EC can stay powered from the battery.
- Whether the 22 W policy holds on a clean boot or beyond 5.5 minutes. Its margin is about 1 C.
- What exceeding 65 C risks on the charger circuit, and what writes the PCIe root port's target speed during a brake.

## 5. Next steps

Each step needs the previous one to pass.

**Step 1: full shutdown, then power on.** Not a restart.

**Step 2: confirm the brake is back.** Start the guard in Terminal 1. It reads SEN6 and stops Strata at 68 C. It was tested with its stop action stubbed out.

```bash
Z=$(grep -lx SEN6 /sys/class/thermal/thermal_zone*/type | xargs dirname); while sleep 1; do T=$(( $(cat $Z/temp)/1000 )); echo -ne "\rSEN6 $T C "; if (( T >= 68 )); then ~/.local/bin/strata launch --stop </dev/null; echo STOPPED; break; fi; done
```

Run the balanced arm only in Terminal 2 (about 9 min). **Do not run the full trace**: its performance arm could reach about 69-72 C if the brake is still off, and Linux only logs the 70 C critical trip.

```bash
cd ~/Downloads/AI-Runtime
TRACE_ROUNDS=6 bash <(sed 's/^ARMS=.*/ARMS="balanced"/' strata-throttle-trace.sh)
```

- **Brake at SEN6 65 C:** the flag is clear. Continue.
- **No brake while SEN6 passes 65 C:** the flag survived. Stop long heavy loads and work out how to reset the EC before going further.
- **SEN6 never reached 65 C:** inconclusive. Repeat with more rounds.

**Step 3: 30-minute soak of the custom policy, guard still running.** Risk is low: it changes CPU power limits only while running, and Ctrl+C restores them. `git checkout -- sen6-test-thermald.sh` undoes the `sed`.

```bash
# Terminal 2
cd ~/Downloads/AI-Runtime
sed -i 's/t0 < 720/t0 < 2400/' sen6-test-thermald.sh
sudo ./sen6-test-thermald.sh custom

# Terminal 3 (about 31 min), then Ctrl+C in Terminal 2 when it ends
cd ~/Downloads/AI-Runtime
TRACE_ROUNDS=22 bash <(sed 's/^ARMS=.*/ARMS="balanced"/' strata-throttle-trace.sh)
```

- **Pass:** no brake, and SEN6 below 65 C for the whole run.
- **SEN6 reaches 65 C:** lower `<TargetState>` in `sen6-thermald-custom.xml`. By the fit, 20 W adds only about 0.4 C and 18 W about 0.8 C, so also consider active cooling.

**Step 4: only after a pass, and only if the user decides:**

```bash
sudo ~/Downloads/AI-Runtime/sen6-install-thermald.sh     # persistent
sudo ~/Downloads/AI-Runtime/sen6-uninstall-thermald.sh   # rollback
```

The installer's override removes the stock service's `--adaptive` flag. Never enable `thermald.service` by hand, because the stock unit would trigger `_OSC`. After install, check that `current_uuid` still reads `INVALID`.

**Step 5, afterwards:** cold-start sensor check (section 6 of the report), update the README status footer, then decide about the 24-run suite.

## 6. Reading the results

Trace files are `strata-throttle-trace-YYYYMMDD-HHMM-N-arm.jsonl`.

- `type=s` is one second: `tok`, `cw` (CPU W), `gw` (GPU W), `pmax` (highest P-core MHz), `pcie` (link generation), `zones.SEN6`, `pl1` (MSR limit), `mpl1` (MMIO limit).
- `type=req` is one request: `round`, `n`, `first`, `last`. Speed is `sum(n) / sum(last - first)`.
- **A brake** is a run of consecutive seconds with `pmax <= 500` containing at least 8 seconds with `tok > 0`. Ignore a single low sample at the end of a run, and exclude power-saver arms, which legitimately run at 400-600 MHz.
- Report steady rounds separately. Early rounds run before SEN6 reaches the cap and flatter the average.

Telemetry from the test script is `sen6-thermald-custom-telemetry.txt`, with SEN6, MHz, both PL1 values, 0x64F bit 10 and the UUID per second. Bit 10 is also set during normal thermald capping, so it does not identify a brake by itself. A new run overwrites this file and `sen6-thermald-custom.log`. The earlier telemetry is in git.

## 7. Files and git

| Path | Purpose |
|---|---|
| `2026-11-23-xps15-sen6-research-result-opus-5.5.md` | Canonical report, with review of Grok and Neon |
| `2026-11-23-xps15-sen6-research-result-neon.md` | Neon's report, corrected in `a89c2b0` |
| `2026-11-23-xps15-sen6-research-result-neon-web.md` | Neon's web-only pass. It still names PROCHOT, which the registers rule out |
| `2026-11-23-xps15-sen6-research-result-grok.md` | Grok's report, also PROCHOT-based |
| `sen6-diag-*.txt`, `sen6-thermald-*` | Register captures, telemetry and thermald test runs |
| `sen6-test-thermald.sh`, `sen6-thermald-custom.xml` | Foreground test and the 22 W policy |
| `sen6-install-thermald.sh`, `sen6-uninstall-thermald.sh` | Persistent install and rollback, **not run** |
| `xps15-sen6-research/` | `msr-watch.py`, `static-check.sh`, redacted turbostat, BIOS values, register snapshot, ACPI tables |

**Git:** `origin` is the public `SvenMeyer/xps15-9530-inference`. `xps15-sen6-research` is pushed at `a89c2b0`, and `main` is unchanged at `35f7d69`.

**Uncommitted:** the Opus report (latest review and plan) and this handover.

**Keep out of git:** `sen6-diag-turbostat.txt` (disk UUIDs), `BIOS-Check_1.13.0.txt` (has a Serial Number field), the ACPI dumps and the thermald debug logs.

**Open risk: do not run `export-to-repo.sh` as it stands.** It copies every root `*.txt` and most `*.log` files to the separate public `local-llm-bench` repo, which includes the two files above. Its secret scan does not look for UUIDs or serial numbers. It would also publish all root `*.md` reports and this handover. The user has not decided about that export.

## 8. Lost at shutdown

`/tmp` is tmpfs, so `/tmp/acpi-dump` and the old session's scratch scripts disappear. Nothing there is needed: the decoded policy tables are in the reports, and the raw ACPI tables are saved. To decompile again without sudo:

```bash
d=$(mktemp -d); cp ~/Downloads/AI-Runtime/xps15-sen6-research/xps15-sen6-check-20261124-0011/acpi/SSDT4.aml "$d"/
cd "$d" && iasl -d SSDT4.aml
grep -n -E 'Device \(SEN6\)|Method \(DPST|Method \(_OSC' SSDT4.dsl
```
