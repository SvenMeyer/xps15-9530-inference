#!/usr/bin/env bash
# Reversible foreground test for Option A: GPU max graphics clock cap (nvidia-smi -lgc)
# + fixed CPU RAPL PL1 limit on Dell XPS 15 9530 WITHOUT thermald or ACPI _OSC.
#
# Usage:
#   sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh [gpu_max_mhz] [cpu_watts] [max_secs] [gpu_max_mem_mhz]
# Defaults (validated safe clean-boot sweet spot: ~20.4 t/s steady, 48.4 W total, 0 full EC brakes, 0 s PCIe Gen 1):
#   gpu_max_mhz=1200  cpu_watts=24  max_secs=0 (run until Ctrl-C)  gpu_max_mem_mhz=5501
# Example (use validated safe defaults):
#   sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh
# Example (custom, timed 40 min, full VRAM):
#   sudo /home/sum/Downloads/AI-Runtime/sen6-test-gpu-cpu-cap.sh 1200 22 2400 0
#
# Undo / Stop: Press Ctrl-C — runs nvidia-smi -rgc / -rmc and restores original RAPL PL1 automatically.
set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0 [gpu_max_mhz] [cpu_watts] [max_secs] [gpu_max_mem_mhz]" >&2
  exit 1
fi

GPU_MHZ="${1:-1200}"
CPU_W="${2:-24}"
MAX_SECS="${3:-0}"
GPU_MEM_MHZ="${4:-5501}"

for v in "$GPU_MHZ" "$CPU_W" "$MAX_SECS" "$GPU_MEM_MHZ"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "All arguments must be positive integers: gpu_max_mhz cpu_watts [max_secs] [gpu_max_mem_mhz]" >&2
    exit 1
  fi
done
if (( GPU_MHZ < 600 || GPU_MHZ > 2400 || CPU_W < 10 || CPU_W > 115 )); then
  echo "Safety bounds exceeded (GPU_MHZ: 600..2400, CPU_W: 10..115)." >&2
  exit 1
fi

OUT_DIR="/home/sum/Downloads/AI-Runtime"
LOG_OUT="$OUT_DIR/sen6-gpu-cpu-cap.log"
TEL_OUT="$OUT_DIR/sen6-gpu-cpu-cap-telemetry.txt"

RAPL_MSR="/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
RAPL_MMIO="/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"

ORIG_MSR=$(cat "$RAPL_MSR" 2>/dev/null || echo "")
ORIG_MMIO=$(cat "$RAPL_MMIO" 2>/dev/null || echo "")

CLEANED=0
cleanup() {
  (( CLEANED )) && return
  CLEANED=1
  echo ""
  echo ">>> Resetting GPU clocks (nvidia-smi -rgc / -rmc) and restoring original RAPL PL1..."
  nvidia-smi -rgc 2>&1 || true
  (( GPU_MEM_MHZ > 0 )) && { nvidia-smi -rmc 2>&1 || true; }
  [[ -n "$ORIG_MSR" && -w "$RAPL_MSR" ]] && echo "$ORIG_MSR" > "$RAPL_MSR" 2>/dev/null || true
  [[ -n "$ORIG_MMIO" && -w "$RAPL_MMIO" ]] && echo "$ORIG_MMIO" > "$RAPL_MMIO" 2>/dev/null || true
  chmod a+r "$LOG_OUT" "$TEL_OUT" 2>/dev/null || true
  echo ">>> Restored: PL1_msr=$(cat "$RAPL_MSR" 2>/dev/null) uW | PL1_mmio=$(cat "$RAPL_MMIO" 2>/dev/null) uW"
  echo ">>> Outputs: $LOG_OUT and $TEL_OUT"
}
trap cleanup EXIT INT TERM

{
  echo "=== TIMESTAMP: $(date -Is) ==="
  echo "Requested: GPU_MAX_CLK=${GPU_MHZ}MHz (range 210,${GPU_MHZ}), CPU_PL1=${CPU_W}W, MAX_SECS=${MAX_SECS}s"
  echo "Saved originals: PL1_msr=${ORIG_MSR}uW, PL1_mmio=${ORIG_MMIO}uW"
  echo "INT3400 UUID: $(cat /sys/bus/platform/devices/INTC10A0:00/uuids/current_uuid 2>/dev/null)"
  echo "=== APPLYING GPU GRAPHICS CLOCK CEILING ==="
  LGC_OUT=$(nvidia-smi -lgc "210,${GPU_MHZ}" 2>&1)
  LGC_RC=$?
  echo "$LGC_OUT"
  if (( LGC_RC != 0 )) || grep -qiE 'not supported|failed|error' <<<"$LGC_OUT"; then
    echo "ERROR: nvidia-smi -lgc 210,${GPU_MHZ} not supported or failed!" >&2
    exit 1
  fi
  if (( GPU_MEM_MHZ > 0 )); then
    echo "=== APPLYING GPU MEMORY CLOCK CEILING (405,${GPU_MEM_MHZ} MHz) ==="
    LMC_OUT=$(nvidia-smi -lmc "405,${GPU_MEM_MHZ}" 2>&1)
    LMC_RC=$?
    echo "$LMC_OUT"
    if (( LMC_RC != 0 )) || grep -qiE 'not supported|failed|error' <<<"$LMC_OUT"; then
      echo "ERROR: nvidia-smi -lmc 405,${GPU_MEM_MHZ} not supported or failed!" >&2
      exit 1
    fi
  fi
  echo "=== APPLYING CPU RAPL PL1 ==="
  CPU_UW=$(( CPU_W * 1000000 ))
  echo "$CPU_UW" > "$RAPL_MSR"
  echo "$CPU_UW" > "$RAPL_MMIO"
  echo "Verified PL1_msr : $(cat "$RAPL_MSR") uW"
  echo "Verified PL1_mmio: $(cat "$RAPL_MMIO") uW"
} | tee "$LOG_OUT"
PIPE_RC=${PIPESTATUS[0]}
chmod a+r "$LOG_OUT" 2>/dev/null || true
if (( PIPE_RC != 0 )); then
  exit "$PIPE_RC"
fi

MEM_LABEL=""
(( GPU_MEM_MHZ > 0 )) && MEM_LABEL=", VRAM<=${GPU_MEM_MHZ}MHz"
TIME_LABEL="max ${MAX_SECS}s"
(( MAX_SECS == 0 )) && TIME_LABEL="until Ctrl-C"
echo ""
echo ">>> READY FOR STRATA BENCH (GPU<=${GPU_MHZ}MHz${MEM_LABEL}, CPU=${CPU_W}W) — logging telemetry to $TEL_OUT (${TIME_LABEL})..."

/usr/bin/python3 - "$TEL_OUT" "$MAX_SECS" <<'PY'
import glob, subprocess, sys, time

out = sys.argv[1]
max_secs = int(sys.argv[2])
def rf(p):
    try: return open(p).read().strip()
    except Exception: return ""
def rtemp(p):
    if not p: return -1.0
    v = rf(p)
    return int(v) / 1000.0 if v.lstrip("-").isdigit() else -1.0
def rwatt(p):
    v = rf(p)
    return int(v) / 1e6 if v.isdigit() else -1.0

zmap = {}
for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
    zt = rf(z + "/type")
    if zt: zmap[zt] = z + "/temp"

t0 = time.time()
with open(out, "w") as f:
    while max_secs == 0 or (time.time() - t0 < max_secs):
        ts = time.strftime("%H:%M:%S")
        sen6 = rtemp(zmap.get("SEN6", ""))
        skin = rtemp(zmap.get("SKIN", ""))
        sen5 = rtemp(zmap.get("SEN5", ""))
        mhz = int(rf("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq") or "0") // 1000
        pl1_msr = rwatt("/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")
        pl1_mmio = rwatt("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw")
        uuid = rf("/sys/bus/platform/devices/INTC10A0:00/uuids/current_uuid")
        try:
            nv = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=power.draw,clocks.gr,clocks.mem,pcie.link.gen.current", "--format=csv,noheader,nounits"],
                text=True, timeout=2
            ).strip().split(",")
            gw, gclk, mclk, pcie = float(nv[0]), int(float(nv[1])), int(float(nv[2])), nv[3].strip()
        except Exception:
            gw, gclk, mclk, pcie = -1.0, -1, -1, "?"
        line = (
            f"{ts} SEN6={sen6:5.2f} SKIN={skin:5.2f} SEN5={sen5:5.2f} MHz={mhz:4d} "
            f"GPU={gw:4.1f}W {gclk:4d}/{mclk:4d}MHz PCIe=G{pcie} PL1={pl1_msr:4.1f}/{pl1_mmio:4.1f}W uuid={uuid}"
        )
        print(line, flush=True)
        f.write(line + "\n")
        f.flush()
        time.sleep(1)
PY
