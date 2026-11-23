#!/usr/bin/env bash
# Persistent install of the validated custom SEN6 thermald policy on Dell XPS 15 9530.
# - Installs /etc/thermald/thermal-conf.xml (root:root, 0644) from sen6-thermald-custom.xml
# - Adds a systemd drop-in override to drop Manjaro's default --adaptive flag so thermald
#   enforces our SEN6 63C->22W policy instead of Dell's 15W SEN5 GDDV clamp.
# - Enables and starts thermald.service and logs verification to sen6-install-thermald.log.
#
# Run as:   sudo /home/sum/Downloads/AI-Runtime/sen6-install-thermald.sh
# Rollback: sudo /home/sum/Downloads/AI-Runtime/sen6-uninstall-thermald.sh
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

SRC_XML="/home/sum/Downloads/AI-Runtime/sen6-thermald-custom.xml"
DST_XML="/etc/thermald/thermal-conf.xml"
DROPIN_DIR="/etc/systemd/system/thermald.service.d"
DROPIN_FILE="$DROPIN_DIR/override.conf"
LOG_OUT="/home/sum/Downloads/AI-Runtime/sen6-install-thermald.log"

if [[ ! -f "$SRC_XML" ]]; then
  echo "Missing source XML: $SRC_XML" >&2
  exit 1
fi

{
  echo "=== TIMESTAMP ==="
  date -Is

  echo "=== INSTALL /etc/thermald/thermal-conf.xml ==="
  install -d -o root -g root -m 0755 /etc/thermald
  install -o root -g root -m 0644 "$SRC_XML" "$DST_XML"
  ls -la "$DST_XML"

  echo "=== INSTALL SYSTEMD OVERRIDE (remove --adaptive, use custom XML) ==="
  install -d -o root -g root -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/thermald --systemd --dbus-enable --config-file=/etc/thermald/thermal-conf.xml
EOF
  chmod 0644 "$DROPIN_FILE"
  cat "$DROPIN_FILE"

  echo "=== ENABLE & RESTART thermald.service ==="
  systemctl daemon-reload
  systemctl enable --now thermald.service
  systemctl restart thermald.service
  sleep 2

  echo "=== VERIFY SERVICE STATUS ==="
  systemctl --no-pager -l status thermald.service || true

  echo "=== VERIFY RUNNING CMDLINE & RAPL PL1 ==="
  ps -ef | grep '[t]hermald' || true
  echo "PL1_msr =$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo N/A) uW"
  echo "PL1_mmio=$(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 2>/dev/null || echo N/A) uW"

  echo "=== RECENT JOURNAL LOGS ==="
  journalctl -u thermald.service -n 25 --no-pager || true
} | tee "$LOG_OUT"

chmod a+r "$LOG_OUT"
echo ">>> Install verification log saved to $LOG_OUT"
