#!/usr/bin/env bash
# Rollback / uninstall for the persistent custom SEN6 thermald policy.
# Run as: sudo /home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

LOG_OUT="/home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.log"

{
  echo "=== TIMESTAMP ==="
  date -Is
  systemctl disable --now thermald.service || true
  rm -f /etc/systemd/system/thermald.service.d/override.conf
  rmdir /etc/systemd/system/thermald.service.d 2>/dev/null || true
  rm -f /etc/thermald/thermal-conf.xml
  systemctl daemon-reload
  echo 115000000 > /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || true
  echo 115000000 > /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 2>/dev/null || true
  echo "Restored PL1_msr=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) uW"
  echo "Restored PL1_mmio=$(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 2>/dev/null) uW"
  systemctl is-active thermald.service || true
} | tee "$LOG_OUT"

chmod a+r "$LOG_OUT"
echo ">>> Rollback complete ($LOG_OUT)"
