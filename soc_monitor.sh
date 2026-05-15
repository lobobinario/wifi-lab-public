#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-wlan0}"
LOG_DIR="${LOG_DIR:-/var/log/enterprise}"
DURATION_SEC="${DURATION_SEC:-300}"   # default 5 min capture
ROTATE_COUNT="${ROTATE_COUNT:-5}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Run as root: sudo ./soc_monitor.sh"
  exit 1
fi

mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
PCAP_FILE="${LOG_DIR}/capture_${TIMESTAMP}.pcap"

TCPDUMP_PID=""

cleanup() {
  echo
  echo "[+] Stopping capture..."
  if [[ -n "${TCPDUMP_PID}" ]]; then
    kill "${TCPDUMP_PID}" 2>/dev/null || true
    wait "${TCPDUMP_PID}" 2>/dev/null || true
  fi
  # Keep only latest N captures
  ls -1t "${LOG_DIR}"/capture_*.pcap 2>/dev/null | tail -n +$((ROTATE_COUNT + 1)) | xargs -r rm -f
  echo "[+] Capture saved: ${PCAP_FILE}"
  exit 0
}

trap cleanup INT TERM

echo "[+] SOC monitoring capture"
echo "[i] Interface: ${IFACE}"
echo "[i] Duration: ${DURATION_SEC}s (Ctrl+C to stop early)"
echo "[i] Output: ${PCAP_FILE}"

tcpdump -i "${IFACE}" -n -s 0 -w "${PCAP_FILE}" &
TCPDUMP_PID=$!

# Wait up to DURATION_SEC, but exit immediately if Ctrl+C
sleep "${DURATION_SEC}" &
SLEEP_PID=$!
wait "${SLEEP_PID}"

cleanup