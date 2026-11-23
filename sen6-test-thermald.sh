#!/usr/bin/env bash
# Reversible foreground test for thermald on Dell XPS 15 9530.
# Does NOT enable thermald.service; restores saved RAPL PL1 on exit/Ctrl-C.
#
# Usage:
#   sudo /home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh adaptive
#   sudo /home/sum/Downloads/AI-Runtime/sen6-test-thermald.sh custom
set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0 [adaptive|custom]" >&2
  exit 1
fi

MODE="${1:-adaptive}"
if [[ "$MODE" != "adaptive" && "$MODE" != "custom" ]]; then
  echo "Usage: sudo $0 [adaptive|custom]" >&2
  exit 1
fi

if ! command -v thermald >/dev/null 2>&1; then
  echo "thermald is not installed. Install it first with:" >&2
  echo "  sudo pacman -S --needed thermald" >&2
  exit 1
fi

OUT_DIR="/home/sum/Downloads/AI-Runtime"
LOG_OUT="$OUT_DIR/sen6-thermald-${MODE}.log"
TEL_OUT="$OUT_DIR/sen6-thermald-${MODE}-telemetry.txt"
XML_CFG="$OUT_DIR/sen6-thermald-custom.xml"

RAPL_MSR="/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
RAPL_MMIO="/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"
ORIG_MSR=$(cat "$RAPL_MSR" 2>/dev/null || echo "")
ORIG_MMIO=$(cat "$RAPL_MMIO" 2>/dev/null || echo "")
THD_PID=""

cleanup() {
  echo ""
  echo ">>> Stopping thermald and restoring original RAPL PL1..."
  if [[ -n "$THD_PID" ]]; then
    kill "$THD_PID" 2>/dev/null || true
    wait "$THD_PID" 2>/dev/null || true
  fi
  [[ -n "$ORIG_MSR" && -w "$RAPL_MSR" ]] && echo "$ORIG_MSR" > "$RAPL_MSR" 2>/dev/null || true
  [[ -n "$ORIG_MMIO" && -w "$RAPL_MMIO" ]] && echo "$ORIG_MMIO" > "$RAPL_MMIO" 2>/dev/null || true
  rm -f /tmp/sen6-thermald-custom.xml 2>/dev/null || true
  chmod a+r "$LOG_OUT" "$TEL_OUT" 2>/dev/null || true
  echo ">>> Restored MSR PL1=$(cat "$RAPL_MSR" 2>/dev/null) uW, MMIO PL1=$(cat "$RAPL_MMIO" 2>/dev/null) uW"
  echo ">>> Outputs: $LOG_OUT and $TEL_OUT"
}
trap cleanup EXIT INT TERM

if [[ "$MODE" == "adaptive" ]]; then
  echo ">>> Starting thermald --no-daemon --loglevel=debug --adaptive (replicating Windows Dell GDDV)..."
  thermald --no-daemon --loglevel=debug --adaptive >"$LOG_OUT" 2>&1 &
else
  # thermald refuses config files not owned by root:root (returns EPERM)
  install -o root -g root -m 0600 "$XML_CFG" /tmp/sen6-thermald-custom.xml
  echo ">>> Starting thermald --no-daemon --loglevel=debug --config-file=/tmp/sen6-thermald-custom.xml (custom SEN6 policy)..."
  thermald --no-daemon --loglevel=debug --config-file=/tmp/sen6-thermald-custom.xml >"$LOG_OUT" 2>&1 &
fi
THD_PID=$!
sleep 3

if ! kill -0 "$THD_PID" 2>/dev/null; then
  echo ">>> thermald exited early! Tail of $LOG_OUT:"
  tail -n 40 "$LOG_OUT"
  exit 1
fi

if [[ "$MODE" == "custom" ]]; then
  if grep -q "Could not open file" "$LOG_OUT"; then
    echo ">>> ERROR: thermald could not open custom XML!" >&2
    grep -i "Could not open file" "$LOG_OUT" >&2
    exit 1
  fi
  echo ">>> Verified ZONE DUMP from $LOG_OUT:"
  sed -n '/ZONE DUMP BEGIN/,/ZONE DUMP END/p' "$LOG_OUT"
fi

chmod a+r "$LOG_OUT" 2>/dev/null || true
echo ">>> thermald running (PID $THD_PID). First 20 log lines:"
head -n 20 "$LOG_OUT"
echo ""
echo ">>> READY FOR STRATA BENCH — logging telemetry to $TEL_OUT (Ctrl-C when Strata run finishes, max 12 min)..."

/usr/bin/python3 - "$TEL_OUT" <<'PY'
import os, struct, sys, time

out = sys.argv[1]
fd0 = os.open("/dev/cpu/0/msr", os.O_RDONLY)
def r_msr(reg): return struct.unpack("<Q", os.pread(fd0, 8, reg))[0]
def rf(p):
    try: return open(p).read().strip()
    except Exception: return ""
def rtemp(p):
    v = rf(p)
    return int(v) / 1000.0 if v.lstrip("-").isdigit() else -1.0
def rwatt(p):
    v = rf(p)
    return int(v) / 1e6 if v.isdigit() else -1.0

t0 = time.time()
with open(out, "w") as f:
    while time.time() - t0 < 720:
        ts = time.strftime("%H:%M:%S")
        sen6 = rtemp("/sys/class/thermal/thermal_zone6/temp")
        sen5 = rtemp("/sys/class/thermal/thermal_zone5/temp")
        skin = rtemp("/sys/class/thermal/thermal_zone0/temp")
        mhz = int(rf("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq") or "0") // 1000
        pl1_msr = rwatt("/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")
        pl1_mmio = rwatt("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw")
        m64f = r_msr(0x64f)
        b10 = (m64f >> 10) & 1
        uuid = rf("/sys/bus/platform/devices/INTC10A0:00/uuids/current_uuid")
        line = (
            f"{ts} SEN6={sen6:5.2f} SEN5={sen5:5.2f} SKIN={skin:5.2f} MHz={mhz:4d} "
            f"PL1_msr={pl1_msr:5.1f}W PL1_mmio={pl1_mmio:5.1f}W 64F_b10={b10} uuid={uuid}"
        )
        print(line, flush=True)
        f.write(line + "\n")
        f.flush()
        time.sleep(1)
os.close(fd0)
PY
