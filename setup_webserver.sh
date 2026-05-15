#!/usr/bin/env bash
# Installs lab_webserver.py as a systemd service on the Raspberry Pi.
#
# HTTP  → http://192.168.50.1/send
# HTTPS → https://192.168.50.1/send
#
# Usage: sudo ./setup_webserver.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)"; exit 1; }

INSTALL_DIR=/opt/lab-webserver
CERT_DIR=/etc/lab-webserver
LOG_FILE=/var/log/lab_webserver.log
SERVICE_FILE=/etc/systemd/system/lab-webserver.service
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Lab WiFi — Web Server Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Install Python script ──────────────────────────────────────────────────
echo "[1/5] Installing server script..."
mkdir -p "$INSTALL_DIR" "$CERT_DIR"
cp "$SCRIPT_DIR/lab_webserver.py" "$INSTALL_DIR/lab_webserver.py"
chmod 755 "$INSTALL_DIR/lab_webserver.py"

# ── 2. Generate self-signed TLS certificate ───────────────────────────────────
echo "[2/5] Generating self-signed TLS certificate (825 days)..."
openssl req -x509 -newkey rsa:2048 -days 825 \
  -nodes \
  -keyout "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.crt" \
  -subj   "/CN=192.168.50.1/O=Lab WiFi/C=ES" \
  -addext "subjectAltName=IP:192.168.50.1" \
  2>/dev/null
chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
echo "    Certificate → $CERT_DIR/server.crt"

# ── 3. Create log file ────────────────────────────────────────────────────────
echo "[3/5] Creating log file..."
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
echo "    Log → $LOG_FILE"

# ── 4. Install and start systemd service ─────────────────────────────────────
echo "[4/5] Installing systemd service..."
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Lab WiFi – Demo HTTP/HTTPS web server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/lab-webserver/lab_webserver.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable lab-webserver.service 2>/dev/null || true
systemctl stop lab-webserver.service 2>/dev/null || true

# ── 5. Verify ─────────────────────────────────────────────────────────────────
echo "[5/5] Verifying..."
if systemctl cat lab-webserver.service &>/dev/null; then
    echo "    Service: INSTALLED ✓ (stopped — start on demand)"
else
    echo "    Service: FAILED to install"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done! Service installed but NOT started."
echo ""
echo "  Start on demand:"
echo "    sudo ./mitm-control.sh webserver on"
echo ""
echo "  Once running:"
echo "    HTTP  →  http://192.168.50.1/send"
echo "    HTTPS →  https://192.168.50.1/send"
echo "    Tabla →  http://192.168.50.1/visualize"
echo ""
echo "  Note: lab-webserver and nginx share port 80."
echo "  Only one can run at a time."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
