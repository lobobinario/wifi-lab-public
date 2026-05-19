#!/usr/bin/env bash
set -euo pipefail

# Enterprise WiFi Security Lab bootstrap for Raspberry Pi OS Lite (Pi 3)
#
# Default topology (router 4G / sin red cableada):
#   - wlan0 : lab AP for students (hostapd + dnsmasq + mitmproxy transparent)
#   - eth0  : admin interface, static IP 192.168.0.1/24 (laptop ↔ Pi management)
#   - eth1  : uplink to internet via Huawei E3372 4G router (192.168.8.1/24 DHCP)
#
# Topología alternativa (red cableada DHCP disponible):
#   sudo AP_IFACE=wlan0 UPLINK_IFACE=eth0 ./enterprise_lab.sh
#
# Usage:
#   sudo ./enterprise_lab.sh
#   sudo LAB_MODE=wpa2 LAB_WPA2_PASSPHRASE='Secret123!' ./enterprise_lab.sh
#   sudo AP_IFACE=wlan0 UPLINK_IFACE=eth1 ./enterprise_lab.sh
#
# Proxy filtering (both are Python regexes matched against hostname:port):
#   PROXY_IGNORE_HOSTS  — pass these through untouched (no interception).
#                         Default: Apple + Facebook (so device apps keep working).
#   PROXY_ALLOW_HOSTS   — intercept ONLY these hosts; empty = intercept all.
#                         Example: sudo PROXY_ALLOW_HOSTS='example\.com' ./enterprise_lab.sh
#
# Examples:
#   # Only intercept example.com and badssl.com — everything else is transparent
#   sudo PROXY_ALLOW_HOSTS='(example\.com|badssl\.com)' ./enterprise_lab.sh
#
#   # Intercept everything except Apple services
#   sudo PROXY_IGNORE_HOSTS='(apple\.com|icloud\.com|mzstatic\.com)' ./enterprise_lab.sh

AP_IFACE="${AP_IFACE:-wlan0}"
UPLINK_IFACE="${UPLINK_IFACE:-eth1}"
LAB_SUBNET="${LAB_SUBNET:-192.168.50.0/24}"
LAB_GATEWAY="${LAB_GATEWAY:-192.168.50.1}"
LAB_NETMASK="${LAB_NETMASK:-255.255.255.0}"
LAB_DHCP_RANGE_START="${LAB_DHCP_RANGE_START:-192.168.50.10}"
LAB_DHCP_RANGE_END="${LAB_DHCP_RANGE_END:-192.168.50.200}"
LAB_SSID="${LAB_SSID:-CorpNet-Enterprise}"
LAB_CHANNEL="${LAB_CHANNEL:-6}"
LAB_MODE="${LAB_MODE:-open}"                       # open | wpa2
LAB_WPA2_PASSPHRASE="${LAB_WPA2_PASSPHRASE:-ChangeMe123!}"
LAB_COUNTRY="${LAB_COUNTRY:-ES}"

PROXY_PORT="${PROXY_PORT:-8080}"
MITMPROXY_BIN="${MITMPROXY_BIN:-mitmdump}"

# Default: ignore Apple/Facebook so native apps keep working during the demo.
# Set to empty string to intercept everything.
PROXY_IGNORE_HOSTS="${PROXY_IGNORE_HOSTS:-(.+\.apple\.com|.+\.icloud\.com|.+\.mzstatic\.com|.+\.facebook\.com|.+\.fbcdn\.net)}"
# Default: empty = intercept all non-ignored hosts.
PROXY_ALLOW_HOSTS="${PROXY_ALLOW_HOSTS:-}"

# Set to 1 to activate the active content-modification demo addon (Demo B only).
# Requires CA trusted on the client device; editable in mitm_demo_modify.py.
PROXY_DEMO_MODIFY="${PROXY_DEMO_MODIFY:-0}"
# Set to 1 to activate the credential harvesting demo addon.
# Logs POST fields matching credential keywords to journald (enterprise.service).
# For HTTPS: requires CA trusted on client (Demo B). HTTP: works with no CA.
PROXY_CREDENTIAL_LOG="${PROXY_CREDENTIAL_LOG:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_MODIFY_SCRIPT="${PROXY_MODIFY_SCRIPT:-${SCRIPT_DIR}/mitm_demo_modify.py}"
PROXY_CREDENTIAL_SCRIPT="${PROXY_CREDENTIAL_SCRIPT:-${SCRIPT_DIR}/mitm_credential_logger.py}"
PROXY_INJECT_SCRIPT="${PROXY_INJECT_SCRIPT:-${SCRIPT_DIR}/mitm_inject_banner.py}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Run as root: sudo ./enterprise_lab.sh"
  exit 1
fi

# Require a command that must already exist in the base OS image.
# These are NOT apt packages — fail clearly if absent.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Required command not found: $1 — check your OS installation"
    exit 1
  }
}

echo "[+] Enterprise Security Lab setup starting..."
echo "[i] AP_IFACE=${AP_IFACE}  UPLINK_IFACE=${UPLINK_IFACE}  LAB_MODE=${LAB_MODE}"

require_cmd apt-get
require_cmd systemctl
require_cmd ip

# Validate both interfaces exist before doing any work
if ! ip link show "${AP_IFACE}" >/dev/null 2>&1; then
  echo "[!] AP interface not found: ${AP_IFACE}"
  exit 1
fi
if ! ip link show "${UPLINK_IFACE}" >/dev/null 2>&1; then
  echo "[!] Uplink interface not found: ${UPLINK_IFACE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 0) Install required packages
# ---------------------------------------------------------------------------
echo "[+] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  hostapd \
  dnsmasq \
  tcpdump \
  iptables \
  iptables-persistent \
  iproute2 \
  iw \
  wireless-tools \
  ca-certificates \
  python3-pip \
  python3-venv \
  pipx

# Install mitmproxy: try apt first (available on Bookworm), fall back to pipx
# (on Debian 13/trixie the apt package is not available)
echo "[+] Installing mitmproxy..."
if ! command -v "${MITMPROXY_BIN}" >/dev/null 2>&1; then
  apt-get install -y mitmproxy 2>/dev/null || true
fi

if ! command -v "${MITMPROXY_BIN}" >/dev/null 2>&1; then
  echo "[i] apt mitmproxy unavailable — installing via pipx into /usr/local/bin..."
  PIPX_HOME=/opt/mitmproxy PIPX_BIN_DIR=/usr/local/bin pipx install mitmproxy
fi

if ! command -v "${MITMPROXY_BIN}" >/dev/null 2>&1; then
  echo "[!] Could not install ${MITMPROXY_BIN}. Install mitmproxy manually and re-run."
  exit 1
fi
MITM_BIN_PATH="$(command -v ${MITMPROXY_BIN})"
echo "[i] mitmproxy binary: ${MITM_BIN_PATH}"

# ---------------------------------------------------------------------------
# Stop services before rewriting configs
# ---------------------------------------------------------------------------
systemctl stop enterprise.service 2>/dev/null || true
systemctl stop hostapd  2>/dev/null || true
systemctl stop dnsmasq  2>/dev/null || true

# hostapd is masked by default on some Raspberry Pi OS versions — unmask
systemctl unmask hostapd 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1a) Tell NetworkManager to stop managing the AP interface
#     NM and hostapd cannot share wlan0 — NM must yield first.
# ---------------------------------------------------------------------------
if systemctl is-active --quiet NetworkManager; then
  echo "[+] Telling NetworkManager to release ${AP_IFACE}..."
  # Runtime: immediately unmanage
  nmcli device set "${AP_IFACE}" managed no 2>/dev/null || true
  # Persistent: drop-in conf so NM ignores the interface after reboot
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/enterprise_lab.conf <<EOF
# Managed by enterprise_lab.sh — do not edit manually
[keyfile]
unmanaged-devices=interface-name:${AP_IFACE}
EOF
  systemctl reload NetworkManager 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 1b) Assign static IP to AP interface
#    - Applied immediately via ip(8) so hostapd/dnsmasq have the address now
#    - Persisted via a systemd oneshot service (works on all Pi OS versions
#      including Bookworm where ifupdown and dhcpcd are not installed)
# ---------------------------------------------------------------------------
echo "[+] Configuring static IP ${LAB_GATEWAY}/24 on ${AP_IFACE}..."

# Immediate (runtime) — works regardless of init system / NetworkManager state
ip addr flush dev "${AP_IFACE}" 2>/dev/null || true
ip addr add "${LAB_GATEWAY}/24" dev "${AP_IFACE}"
ip link set "${AP_IFACE}" up

# Persistent: systemd oneshot that runs before hostapd/dnsmasq on every boot.
# This replaces the ifupdown/dhcpcd approaches which are absent on Pi OS Bookworm.
cat > /etc/systemd/system/enterprise-lab-ap-ip.service <<EOF
[Unit]
Description=Assign static IP to ${AP_IFACE} (enterprise lab AP interface)
Before=hostapd.service dnsmasq.service enterprise.service
After=sys-subsystem-net-devices-${AP_IFACE}.device
Wants=sys-subsystem-net-devices-${AP_IFACE}.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip addr flush dev ${AP_IFACE}
ExecStart=/sbin/ip addr add ${LAB_GATEWAY}/24 dev ${AP_IFACE}
ExecStart=/sbin/ip link set ${AP_IFACE} up

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable enterprise-lab-ap-ip.service

# ---------------------------------------------------------------------------
# 2) hostapd config
# ---------------------------------------------------------------------------
echo "[+] Writing hostapd config..."
cat > /etc/hostapd/hostapd.conf <<EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${LAB_SSID}
hw_mode=g
channel=${LAB_CHANNEL}
ieee80211d=1
country_code=${LAB_COUNTRY}
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF

if [[ "${LAB_MODE}" == "wpa2" ]]; then
  cat >> /etc/hostapd/hostapd.conf <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=${LAB_WPA2_PASSPHRASE}
rsn_pairwise=CCMP
EOF
fi

# Point the hostapd daemon to our config
if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd 2>/dev/null; then
  sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

# ---------------------------------------------------------------------------
# 3) dnsmasq config
#
# Key design decisions:
#   - bind-interfaces + explicit interface= so dnsmasq only serves wlan0
#   - dhcp-range includes explicit subnet mask (required when interface may
#     not yet have its IP assigned at dnsmasq startup)
#   - dhcp-authoritative so stale/rogue DHCP clients are handled correctly
#   - DNS upstream forwarded to public resolvers so students can reach real
#     sites (TLS interception is done by iptables REDIRECT, not DNS spoofing)
# ---------------------------------------------------------------------------
echo "[+] Writing dnsmasq config..."
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/enterprise_lab.conf <<EOF
# Managed by enterprise_lab.sh — do not edit manually
interface=${AP_IFACE}
bind-interfaces
dhcp-authoritative
dhcp-range=${LAB_DHCP_RANGE_START},${LAB_DHCP_RANGE_END},${LAB_NETMASK},12h
dhcp-option=3,${LAB_GATEWAY}
dhcp-option=6,${LAB_GATEWAY}
server=8.8.8.8
server=8.8.4.4
EOF

# ---------------------------------------------------------------------------
# 4) IP forwarding
# ---------------------------------------------------------------------------
echo "[+] Enabling IP forwarding..."
cat > /etc/sysctl.d/99-enterprise-lab.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 5) iptables: NAT masquerade + transparent proxy redirect
# ---------------------------------------------------------------------------
echo "[+] Configuring iptables rules..."
iptables -F
iptables -t nat -F

# Masquerade AP client traffic through the uplink interface
iptables -A FORWARD -i "${UPLINK_IFACE}" -o "${AP_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "${AP_IFACE}" -o "${UPLINK_IFACE}" -j ACCEPT
iptables -t nat -A POSTROUTING -o "${UPLINK_IFACE}" -j MASQUERADE

# Redirect HTTP and HTTPS (TCP) from AP clients to the local mitmproxy port.
# The '! -d LAB_GATEWAY' exclusion is intentional: PREROUTING intercepts all
# packets arriving on the AP interface, including traffic whose destination is
# the Pi itself. Without this exclusion, connections to the Pi's own IP on
# port 80/443 (e.g. the lab_webserver demo at http://192.168.50.1/) would be
# silently stolen by mitmproxy instead of reaching the intended local service.
iptables -t nat -A PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" -p tcp --dport 80  -j REDIRECT --to-port "${PROXY_PORT}"
iptables -t nat -A PREROUTING -i "${AP_IFACE}" ! -d "${LAB_GATEWAY}" -p tcp --dport 443 -j REDIRECT --to-port "${PROXY_PORT}"

# Block QUIC (HTTP/3 over UDP 443/80) so iOS and Chrome fall back to TCP TLS.
# Without this, modern clients use QUIC and bypass the TCP-based transparent
# proxy entirely — no interception, no certificate warning, no modification.
iptables -I FORWARD -i "${AP_IFACE}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
iptables -I FORWARD -i "${AP_IFACE}" -p udp --dport 80  -j REJECT --reject-with icmp-port-unreachable

# Persist rules across reboots
netfilter-persistent save >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6) mitmproxy transparent proxy launcher
# ---------------------------------------------------------------------------
echo "[+] Writing proxy launcher /usr/local/bin/start_proxy.sh..."
# Build optional mitmproxy flags
PROXY_FILTER_FLAGS=""
if [[ -n "${PROXY_IGNORE_HOSTS}" ]]; then
  PROXY_FILTER_FLAGS="${PROXY_FILTER_FLAGS} --ignore-hosts '${PROXY_IGNORE_HOSTS}'"
fi
if [[ -n "${PROXY_ALLOW_HOSTS}" ]]; then
  PROXY_FILTER_FLAGS="${PROXY_FILTER_FLAGS} --allow-hosts '${PROXY_ALLOW_HOSTS}'"
fi
if [[ "${PROXY_DEMO_MODIFY}" == "1" ]]; then
  if [[ -f "${PROXY_MODIFY_SCRIPT}" ]]; then
    cp "${PROXY_MODIFY_SCRIPT}" /usr/local/bin/mitm_demo_modify.py
    PROXY_FILTER_FLAGS="${PROXY_FILTER_FLAGS} -s /usr/local/bin/mitm_demo_modify.py"
    echo "[i] Content-modification addon enabled: ${PROXY_MODIFY_SCRIPT}"
  else
    echo "[!] PROXY_DEMO_MODIFY=1 but script not found: ${PROXY_MODIFY_SCRIPT}"
    exit 1
  fi
fi
if [[ "${PROXY_CREDENTIAL_LOG}" == "1" ]]; then
  if [[ -f "${PROXY_CREDENTIAL_SCRIPT}" ]]; then
    cp "${PROXY_CREDENTIAL_SCRIPT}" /usr/local/bin/mitm_credential_logger.py
    PROXY_FILTER_FLAGS="${PROXY_FILTER_FLAGS} -s /usr/local/bin/mitm_credential_logger.py"
    echo "[i] Credential logging addon enabled: ${PROXY_CREDENTIAL_SCRIPT}"
  else
    echo "[!] PROXY_CREDENTIAL_LOG=1 but script not found: ${PROXY_CREDENTIAL_SCRIPT}"
    exit 1
  fi
fi

# Always deploy the injection addon to /usr/local/bin so that
# `mitm-control.sh inject on` can toggle it at runtime without re-bootstrap.
# The addon stays OFF by default; activation is opt-in via mitm-control.
if [[ -f "${PROXY_INJECT_SCRIPT}" ]]; then
  cp "${PROXY_INJECT_SCRIPT}" /usr/local/bin/mitm_inject_banner.py
  echo "[i] Injection addon deployed (off by default): /usr/local/bin/mitm_inject_banner.py"
fi

cat > /usr/local/bin/start_proxy.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Transparent mode: mitmproxy intercepts connections redirected by iptables.
# --ignore-hosts : pass through without TLS interception (apps keep working)
# --allow-hosts  : if set, intercept ONLY these hosts
# -s             : optional Python addon for active content modification
exec ${MITM_BIN_PATH} \\
  --mode transparent \\
  --showhost \\
  --listen-port ${PROXY_PORT} \\
  --listen-host 0.0.0.0 \\
  --set tls_version_client_min=TLS1_2 \\
  ${PROXY_FILTER_FLAGS}
EOF
chmod +x /usr/local/bin/start_proxy.sh

# ---------------------------------------------------------------------------
# 7) systemd service for the proxy
# ---------------------------------------------------------------------------
echo "[+] Writing systemd service enterprise.service..."
cat > /etc/systemd/system/enterprise.service <<EOF
[Unit]
Description=Enterprise WiFi TLS Inspection Lab (mitmproxy transparent)
After=network-online.target hostapd.service dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/start_proxy.sh
Restart=on-failure
RestartSec=3
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hostapd dnsmasq enterprise.service
systemctl restart hostapd dnsmasq enterprise.service

# ---------------------------------------------------------------------------
# 8) Wait for mitmproxy CA cert to be generated and report its location
# ---------------------------------------------------------------------------
echo "[i] Waiting for mitmproxy CA cert..."
for i in {1..15}; do
  [[ -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]] && break
  sleep 2
done

if [[ -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]]; then
  echo "[i] CA cert generated: /root/.mitmproxy/mitmproxy-ca-cert.pem"
else
  echo "[!] CA cert not yet present — enterprise.service may still be initialising."
  echo "[i] Check: sudo journalctl -u enterprise.service -n 30 --no-pager"
fi

echo
echo "[+] Setup complete!"
printf "[i] SSID       : %s (%s)\n"  "${LAB_SSID}"             "${LAB_MODE}"
printf "[i] Gateway    : %s\n"        "${LAB_GATEWAY}"
printf "[i] DHCP range : %s – %s\n"  "${LAB_DHCP_RANGE_START}" "${LAB_DHCP_RANGE_END}"
printf "[i] Proxy port : %s\n"        "${PROXY_PORT}"
printf "[i] CA cert    : %s\n"        "/root/.mitmproxy/mitmproxy-ca-cert.pem"
echo   "[i] Next step  : sudo ./lab_precheck.sh"
echo   "[i] Teaching   : follow student_lab.md for the staged demo"
