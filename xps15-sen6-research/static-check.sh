#!/usr/bin/env bash
# Read-only: copies BIOS setting values, the DSDT/SSDT ACPI tables and a few MSRs into a new folder.
# Does not write to any firmware, sysfs or MSR path. Skips service tag, asset tag and other ACPI tables.
# Run: sudo bash xps15-sen6-static-check.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/xps15-sen6-check-$(date +%Y%m%d-%H%M)"
mkdir "$OUT" "$OUT/acpi"
B=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
for a in ThermalManagement TurboMode Speedstep SpeedShift CStatesCtrl AdaptiveCStates CpuCoreExt LogicProc MultipleAtomCores \
         PeakShiftCfg PrimaryBattChargeCfg AdvBatteryChargeCfg IntelSagv ForceLpmAspmOff PcieResizableBar PowerWarn \
         TypeCDockOverride VideoPowerOnlyPorts DisUsb4Pcie; do
  if [[ -r $B/$a/current_value ]]; then printf '%s=%s\n' "$a" "$(cat "$B/$a/current_value" 2>/dev/null || echo unreadable)"; fi
done > "$OUT/bios-settings.txt"
for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do cat "$t" > "$OUT/acpi/$(basename "$t").aml"; done
python3 -I - > "$OUT/msr-static.txt" <<'PY'
import os, struct
fd = os.open("/dev/cpu/0/msr", os.O_RDONLY)
for n, r in (("PLATFORM_INFO",0xCE),("THERM_STATUS",0x19C),("TEMP_TARGET",0x1A2),("PKG_THERM_STATUS",0x1B1),("POWER_CTL",0x1FC),("PKG_POWER_LIMIT",0x610),("PERF_LIMIT_REASONS",0x64F),("PLATFORM_POWER_LIMIT",0x65C)):
    try: print(f"{n} {r:#x} {struct.unpack('<Q', os.pread(fd, 8, r))[0]:#018x}")
    except OSError as e: print(f"{n} {r:#x} unreadable: {e.strerror}")
PY
[[ -n ${SUDO_UID:-} ]] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"
echo "saved: $OUT"; cat "$OUT/bios-settings.txt" "$OUT/msr-static.txt"; ls "$OUT/acpi" | wc -l
