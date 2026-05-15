#!/usr/bin/env bash
set -euo pipefail

AP_IFACE="${AP_IFACE:-wlan0}"
UPLINK_IFACE="${UPLINK_IFACE:-eth1}"
PROXY_PORT="${PROXY_PORT:-8080}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failures=0
warnings=0

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; warnings=$((warnings+1)); }
bad() { echo -e "${RED}[FAIL]${NC} $*"; failures=$((failures+1)); }

check_cmd() {
  command -v "$1" >/dev/null 2>&1 && ok "Command available: $1" || bad "Missing command: $1"
}

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    ok "Service active: $svc"
  else
    bad "Service not active: $svc"
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Run as root: sudo ./lab_precheck.sh"
  exit 1
fi

echo "[+] Enterprise Lab precheck"
echo "[i] AP_IFACE=$AP_IFACE UPLINK_IFACE=$UPLINK_IFACE PROXY_PORT=$PROXY_PORT"

echo
for c in ip iw hostapd dnsmasq iptables systemctl ss tcpdump; do
  check_cmd "$c"
done

echo
if ip link show "$AP_IFACE" >/dev/null 2>&1; then
  ok "AP interface exists: $AP_IFACE"
else
  bad "AP interface not found: $AP_IFACE"
fi

if ip link show "$UPLINK_IFACE" >/dev/null 2>&1; then
  ok "Uplink interface exists: $UPLINK_IFACE"
else
  bad "Uplink interface not found: $UPLINK_IFACE"
fi

echo
if iw dev "$AP_IFACE" info >/dev/null 2>&1; then
  ok "Wireless interface ready: $AP_IFACE"
else
  warn "Could not query wireless info for $AP_IFACE (driver/state issue?)"
fi

echo
check_service hostapd
check_service dnsmasq
check_service enterprise.service

echo
if sysctl net.ipv4.ip_forward | grep -q ' = 1$'; then
  ok "IP forwarding enabled"
else
  bad "IP forwarding disabled"
fi

if iptables -t nat -S | grep -q -- "--dport 80 .* --to-ports\|--to-port"; then
  ok "NAT redirect rule for HTTP present"
else
  warn "No HTTP redirect rule detected"
fi

if iptables -t nat -S | grep -q -- "--dport 443 .* --to-ports\|--to-port"; then
  ok "NAT redirect rule for HTTPS present"
else
  warn "No HTTPS redirect rule detected"
fi

if iptables -t nat -S | grep -qF -- "-A POSTROUTING -o $UPLINK_IFACE -j MASQUERADE"; then
  ok "MASQUERADE rule present for $UPLINK_IFACE"
else
  bad "MASQUERADE rule missing for $UPLINK_IFACE"
fi

echo
if ss -ltnp | grep -q ":${PROXY_PORT} "; then
  ok "Proxy listening on TCP ${PROXY_PORT}"
else
  bad "No process listening on TCP ${PROXY_PORT}"
fi

if [[ -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]]; then
  ok "mitmproxy CA cert present"
else
  warn "mitmproxy CA cert not generated yet (/root/.mitmproxy/mitmproxy-ca-cert.pem)"
fi

# ---------------------------------------------------------------------------
# Addon status — read active -s flags from the generated start_proxy.sh
# ---------------------------------------------------------------------------
echo
PROXY_LAUNCHER="/usr/local/bin/start_proxy.sh"
declare -A ADDON_LABELS=(
  [mitm_demo_modify.py]="Content modification demo  (Gooogle / B1ng replacements)"
  [mitm_credential_logger.py]="Credential harvesting logger (POST field capture)"
)

if [[ ! -f "${PROXY_LAUNCHER}" ]]; then
  warn "Proxy launcher not found: ${PROXY_LAUNCHER} — run enterprise_lab.sh first"
else
  for addon_file in "${!ADDON_LABELS[@]}"; do
    label="${ADDON_LABELS[$addon_file]}"
    if grep -q "${addon_file}" "${PROXY_LAUNCHER}"; then
      ok "Addon ACTIVE   : ${addon_file} — ${label}"
    else
      echo -e "${YELLOW}[OFF]${NC}  Addon inactive : ${addon_file} — ${label}"
    fi
  done

  # Show ignore-hosts and allow-hosts filter configuration
  echo
  ignore=$(grep -oP "(?<=--ignore-hosts ')[^']*" "${PROXY_LAUNCHER}" || true)
  allow=$(grep -oP  "(?<=--allow-hosts ')[^']*"  "${PROXY_LAUNCHER}" || true)
  if [[ -n "${ignore}" ]]; then
    echo -e "${GREEN}[OK]${NC}  Ignore-hosts   : ${ignore}"
  else
    echo -e "${YELLOW}[--]${NC}  Ignore-hosts   : (none — all hosts intercepted)"
  fi
  if [[ -n "${allow}" ]]; then
    echo -e "${GREEN}[OK]${NC}  Allow-hosts    : ${allow}"
  else
    echo -e "${YELLOW}[--]${NC}  Allow-hosts    : (none — no host allowlist active)"
  fi
fi

# ---------------------------------------------------------------------------
# Optional services (informational — not counted as failures)
# ---------------------------------------------------------------------------
echo
echo "[i] Optional services (port 80 — only one can run at a time):"

DNSMASQ_SPOOF="/etc/dnsmasq.d/dns_spoof.conf"
webserver_active=false
nginx_active=false

if systemctl is-active --quiet lab-webserver.service 2>/dev/null; then
  ok  "lab-webserver : RUNNING — http://192.168.50.1/send"
  webserver_active=true
else
  echo -e "${YELLOW}[OFF]${NC}  lab-webserver : stopped  (start: sudo ./mitm-control.sh webserver on)"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  ok  "nginx         : RUNNING — DNS spoof exercise active"
  nginx_active=true
else
  echo -e "${YELLOW}[OFF]${NC}  nginx         : stopped  (start: sudo ./dns-spoof.sh enable)"
fi

if "${webserver_active}" && "${nginx_active}"; then
  warn "Both lab-webserver and nginx are running — port 80 conflict!"
fi

echo
if [[ -f "${DNSMASQ_SPOOF}" ]]; then
  spoof_domain=$(grep -oP "(?<=address=/)[^/]+" "${DNSMASQ_SPOOF}" || echo "unknown")
  spoof_ip=$(grep -oP "(?<=/)[^/]+$" "${DNSMASQ_SPOOF}" || echo "unknown")
  ok  "DNS spoof     : ACTIVE — ${spoof_domain} → ${spoof_ip}"
else
  echo -e "${YELLOW}[OFF]${NC}  DNS spoof     : inactive (enable: sudo ./dns-spoof.sh enable)"
fi

echo
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
  ok "Pi has outbound internet reachability"
else
  warn "No outbound internet reachability from Pi"
fi

echo
if ((failures > 0)); then
  echo -e "${RED}[SUMMARY]${NC} $failures failure(s), $warnings warning(s)"
  exit 2
fi

echo -e "${GREEN}[SUMMARY]${NC} Precheck passed with $warnings warning(s)"
