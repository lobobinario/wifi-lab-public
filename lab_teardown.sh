#!/usr/bin/env bash
set -euo pipefail

AP_IFACE="${AP_IFACE:-wlan0}"
UPLINK_IFACE="${UPLINK_IFACE:-eth1}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[!] Run as root: sudo ./lab_teardown.sh"
  exit 1
fi

echo "[+] Enterprise Lab teardown starting..."

echo "[i] Stopping and disabling services..."
systemctl disable --now enterprise.service 2>/dev/null || true
systemctl disable --now hostapd 2>/dev/null || true
systemctl disable --now dnsmasq 2>/dev/null || true
# Re-mask hostapd to restore Raspberry Pi OS default (if it was masked before)
systemctl mask hostapd 2>/dev/null || true

# Remove the HTTP/HTTPS demo web server if it was installed
if systemctl is-enabled --quiet lab-webserver.service 2>/dev/null || \
   systemctl is-active  --quiet lab-webserver.service 2>/dev/null; then
  echo "[i] Stopping lab-webserver..."
  systemctl disable --now lab-webserver.service 2>/dev/null || true
fi
rm -f  /etc/systemd/system/lab-webserver.service
rm -rf /opt/lab-webserver
rm -rf /etc/lab-webserver
rm -f  /var/log/lab_webserver.log

# Remove NetworkManager unmanaged drop-in and let NM re-manage the AP interface
if [[ -f /etc/NetworkManager/conf.d/enterprise_lab.conf ]]; then
  rm -f /etc/NetworkManager/conf.d/enterprise_lab.conf
  systemctl reload NetworkManager 2>/dev/null || true
  nmcli device set "${AP_IFACE}" managed yes 2>/dev/null || true
fi

rm -f /etc/systemd/system/enterprise.service
systemctl daemon-reload

# Reset runtime firewall rules created by the lab script
echo "[i] Flushing iptables runtime rules..."
iptables -F || true
iptables -t nat -F || true

# Restore forwarding default in runtime (persistent sysctl file removed below)
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
rm -f /etc/sysctl.d/99-enterprise-lab.conf
sysctl --system >/dev/null 2>&1 || true

# Remove dedicated dnsmasq drop-in
rm -f /etc/dnsmasq.d/enterprise_lab.conf

# Remove network interfaces drop-in created by enterprise_lab.sh
rm -f /etc/network/interfaces.d/enterprise_lab_ap

# Remove hostapd config managed by lab
if [[ -f /etc/hostapd/hostapd.conf ]]; then
  cp /etc/hostapd/hostapd.conf "/etc/hostapd/hostapd.conf.bak.$(date +%Y%m%d_%H%M%S)"
  rm -f /etc/hostapd/hostapd.conf
fi

# Best effort: remove the AP interface block from dhcpcd.conf
if [[ -f /etc/dhcpcd.conf ]]; then
  sed -i "/^interface ${AP_IFACE}$/,/^$/d" /etc/dhcpcd.conf || true
fi

# Remove proxy launcher
rm -f /usr/local/bin/start_proxy.sh

# Bring AP interface down/up so NetworkManager/dhcpcd can reclaim it
echo "[i] Cycling interface ${AP_IFACE}..."
ip link set "$AP_IFACE" down || true
sleep 1
ip link set "$AP_IFACE" up || true

# Save now-clean rules (if netfilter-persistent exists)
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "[+] Teardown complete"
echo "[i] Optional: reboot the Pi to fully reset networking state."
