#!/usr/bin/env bash
# Read-only SEN6 diagnostic capture for Dell XPS 15 9530.
# Does NOT modify BIOS, /sys, power profiles, or any MSR.
# Run as: sudo /home/sum/Downloads/AI-Runtime/sen6-diag-readonly.sh
set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

OUT_DIR="/home/sum/Downloads/AI-Runtime"
IDLE_OUT="$OUT_DIR/sen6-diag-idle.txt"
BRAKE_OUT="$OUT_DIR/sen6-diag-brake.txt"
TURBO_OUT="$OUT_DIR/sen6-diag-turbostat.txt"
PCIE_OUT="$OUT_DIR/sen6-diag-pcie-brake.txt"
ACPI_DIR="/tmp/acpi-dump"

fix_perms() {
  chmod a+r "$IDLE_OUT" "$BRAKE_OUT" "$TURBO_OUT" "$PCIE_OUT" 2>/dev/null || true
  chmod -R a+rX "$ACPI_DIR" 2>/dev/null || true
}
trap fix_perms EXIT INT TERM

{
  echo "=== TIMESTAMP ==="
  date -Is

  echo "=== BIOS 1.34.0 ATTRS ==="
  for a in ThermalManagement TurboMode Speedstep CStatesCtrl AdaptiveCStates LogicProc MultipleAtomCores PrimaryBattChargeCfg PeakShiftCfg ForceLpmAspmOff; do
    f="/sys/class/firmware-attributes/dell-wmi-sysman/attributes/$a/current_value"
    [[ -e "$f" ]] && echo "$a=$(cat "$f")"
  done

  echo "=== LSPCI ROOT PORT 00:01.0 (IDLE) ==="
  lspci -vv -s 00:01.0 | grep -E '^00:01\.0|LnkCap:|LnkSta:|LnkCtl:|LnkCtl2:' || true

  echo "=== LSPCI GPU 01:00.0 (IDLE) ==="
  lspci -vv -s 01:00.0 | grep -E '^01:00\.0|LnkCap:|LnkSta:|LnkCtl:|LnkCtl2:' || true

  echo "=== IDLE MSRs (cpu0 P-core & cpu12 E-core, O_RDONLY) ==="
  /usr/bin/python3 - <<'PY'
import os, struct
for cpu, label in [(0, "P-core cpu0"), (12, "E-core cpu12")]:
    fd = os.open(f"/dev/cpu/{cpu}/msr", os.O_RDONLY)
    print(f"--- {label} ---")
    for reg, name in [
        (0x1fc, "MSR_POWER_CTL"),
        (0x19c, "IA32_THERM_STATUS"),
        (0x1b1, "IA32_PKG_THERM_STATUS"),
        (0x64f, "MSR_CORE_PERF_LIMIT_REASONS"),
    ]:
        v = struct.unpack("<Q", os.pread(fd, 8, reg))[0]
        print(f"  0x{reg:03x} {name:28s} = 0x{v:016x}")
    os.close(fd)
PY

  echo "=== DUMP & DECOMPILE ACPI TABLES ==="
  rm -rf "$ACPI_DIR" && mkdir -p "$ACPI_DIR"
  cp /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT* "$ACPI_DIR/"
  (cd "$ACPI_DIR" && iasl -d DSDT SSDT* >"$ACPI_DIR/iasl.log" 2>&1 || true)
  echo "Decompiled .dsl count: $(ls -1 "$ACPI_DIR"/*.dsl 2>/dev/null | wc -l)"
  ls -lh "$ACPI_DIR"/*.dsl 2>/dev/null || true
} | tee "$IDLE_OUT"

fix_perms
echo ""
echo ">>> IDLE SNAPSHOT + ACPI DECOMPILE COMPLETE ($IDLE_OUT, $ACPI_DIR)"
echo ">>> READY FOR STRATA LOAD — auto-watching up to 10 min for 1 SEN6 brake (Ctrl-C to stop early)..."

/usr/bin/python3 - "$BRAKE_OUT" "$TURBO_OUT" "$PCIE_OUT" <<'PY'
import os, struct, subprocess, sys, time

brake_out, turbo_out, pcie_out = sys.argv[1], sys.argv[2], sys.argv[3]
fd0 = os.open("/dev/cpu/0/msr", os.O_RDONLY)
def r(reg): return struct.unpack("<Q", os.pread(fd0, 8, reg))[0]

def rtemp(path):
    try: return int(open(path).read().strip()) / 1000.0
    except Exception: return -1.0

brake_secs = 0
captured_mid = False
released_secs = None
t0 = time.time()

with open(brake_out, "w") as f:
    while time.time() - t0 < 600:
        ts = time.strftime("%H:%M:%S")
        sen6 = rtemp("/sys/class/thermal/thermal_zone6/temp")
        sen5 = rtemp("/sys/class/thermal/thermal_zone5/temp")
        skin = rtemp("/sys/class/thermal/thermal_zone0/temp")
        mhz = int(open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq").read()) // 1000
        m19c, m1b1, m1fc, m64f = r(0x19c), r(0x1b1), r(0x1fc), r(0x64f)
        lnk = subprocess.check_output(["lspci", "-vv", "-s", "01:00.0"], text=True)
        lsta = next((l.strip() for l in lnk.splitlines() if "LnkSta:" in l), "")
        lctl2 = next((l.strip() for l in lnk.splitlines() if "LnkCtl2:" in l), "")
        line = (
            f"{ts} SEN6={sen6:.2f} SEN5={sen5:.2f} SKIN={skin:.2f} MHz={mhz:4d} "
            f"19C=0x{m19c:016x} 1B1=0x{m1b1:016x} 1FC=0x{m1fc:016x} 64F=0x{m64f:016x} "
            f"| {lsta} | {lctl2}"
        )
        print(line, flush=True)
        f.write(line + "\n")
        f.flush()

        if mhz <= 450 and sen6 >= 64.0:
            brake_secs += 1
            if brake_secs == 5 and not captured_mid:
                captured_mid = True
                subprocess.run(
                    ["turbostat", "--debug", "--num_iterations", "1", "--interval", "1"],
                    stdout=open(turbo_out, "w"),
                    stderr=subprocess.STDOUT,
                )
                with open(pcie_out, "w") as pf:
                    subprocess.run(["lspci", "-vv", "-s", "00:01.0"], stdout=pf, stderr=subprocess.STDOUT)
                    subprocess.run(["lspci", "-vv", "-s", "01:00.0"], stdout=pf, stderr=subprocess.STDOUT)
                os.chmod(turbo_out, 0o644)
                os.chmod(pcie_out, 0o644)
                print(f">>> CAPTURED MID-BRAKE TURBOSTAT ({turbo_out}) + LSPCI ({pcie_out})", flush=True)
        elif brake_secs >= 10 and mhz >= 1500:
            released_secs = 0 if released_secs is None else released_secs + 1
            if released_secs >= 10:
                print(">>> BRAKE RELEASED — DONE", flush=True)
                break
        time.sleep(1)

os.close(fd0)
PY

fix_perms
echo ">>> ALL OUTPUTS READY:"
ls -lh "$IDLE_OUT" "$BRAKE_OUT" "$TURBO_OUT" "$PCIE_OUT" 2>/dev/null || true
