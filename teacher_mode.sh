#!/usr/bin/env bash
set -euo pipefail

# One-command launcher for class day
# 1) Optional setup
# 2) Precheck
# 3) Optional SOC capture in background
# 4) Quick status summary

RUN_SETUP="${RUN_SETUP:-0}"        # 1 = run enterprise_lab.sh first
RUN_CAPTURE="${RUN_CAPTURE:-1}"    # 1 = launch soc_monitor.sh in background
CAPTURE_DURATION="${CAPTURE_DURATION:-1800}"  # 30 min default
AP_IFACE="${AP_IFACE:-wlan0}"
UPLINK_IFACE="${UPLINK_IFACE:-eth0}"
LOG_DIR="${LOG_DIR:-/var/log/enterprise}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Run as root: sudo ./teacher_mode.sh"
  exit 1
fi

echo "[+] Teacher mode starting"
echo "[i] RUN_SETUP=$RUN_SETUP RUN_CAPTURE=$RUN_CAPTURE CAPTURE_DURATION=${CAPTURE_DURATION}s"

if [[ "$RUN_SETUP" == "1" ]]; then
  echo "[+] Running lab setup..."
  AP_IFACE="$AP_IFACE" UPLINK_IFACE="$UPLINK_IFACE" ./enterprise_lab.sh
fi

echo "[+] Running precheck..."
AP_IFACE="$AP_IFACE" UPLINK_IFACE="$UPLINK_IFACE" ./lab_precheck.sh

echo "[+] Service snapshot"
systemctl --no-pager --full status hostapd dnsmasq enterprise.service | sed -n '1,60p'

echo "[+] Network snapshot"
ip -brief a show "$AP_IFACE" "$UPLINK_IFACE" || true

if [[ "$RUN_CAPTURE" == "1" ]]; then
  echo "[+] Starting background capture..."
  mkdir -p "$LOG_DIR"
  nohup IFACE="$AP_IFACE" DURATION_SEC="$CAPTURE_DURATION" LOG_DIR="$LOG_DIR" ./soc_monitor.sh >"$LOG_DIR/teacher_mode_capture.log" 2>&1 &
  echo "[i] Capture PID: $!"
  echo "[i] Capture log: $LOG_DIR/teacher_mode_capture.log"
fi

echo
echo "[+] Teacher mode ready"
echo "[i] Suggested classroom flow:"
echo "    1) Demo A: HTTPS without trusted CA (warnings/alerts)"
echo "    2) Demo B: managed trust on lab-only device"
echo "    3) Debrief: public WiFi risk vs corporate managed inspection"
