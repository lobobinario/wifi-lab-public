#!/usr/bin/env bash
set -euo pipefail

# dns-spoof.sh — DNS spoofing lab exercise.
# Redirects a domain to a local nginx fake page to demonstrate how an AP
# with DNS control can silently deceive connected clients.
#
# Architecture:
#   - dnsmasq spoof entry: *.SPOOF_DOMAIN → LAB_GATEWAY (192.168.50.1)
#   - nginx serves on port 80 — mutually exclusive with lab_webserver
#   - enable stops lab_webserver first; disable only stops nginx
#   - no IP alias or extra iptables rules needed: existing ! -d LAB_GATEWAY
#     rule already bypasses mitmproxy for traffic to 192.168.50.1
#
# Usage:
#   sudo ./dns-spoof.sh enable    # start the exercise
#   sudo ./dns-spoof.sh disable   # stop the exercise (default state)
#   sudo ./dns-spoof.sh status    # show current state

SPOOF_DOMAIN="${SPOOF_DOMAIN:-elmundo.es}"
LAB_GATEWAY="${LAB_GATEWAY:-192.168.50.1}"
AP_IFACE="${AP_IFACE:-wlan0}"

DNSMASQ_CONF="/etc/dnsmasq.d/dns_spoof.conf"
NGINX_CONF="/etc/nginx/sites-available/fake-elmundo"
NGINX_ENABLED="/etc/nginx/sites-enabled/fake-elmundo"
WEB_ROOT="/var/www/fake-elmundo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ "${EUID}" -ne 0 ]] && { echo "[!] Run as root: sudo $0"; exit 1; }

# ---------------------------------------------------------------------------
# Asset installation (runs on first enable)
# ---------------------------------------------------------------------------

write_assets() {
  if ! command -v nginx &>/dev/null; then
    echo "[+] Installing nginx..."
    # || true: post-install systemctl may return non-zero in non-interactive mode
    # even when the package installs correctly; verify with command -v afterwards
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>/dev/null || true
    command -v nginx &>/dev/null || { echo -e "${RED}[!]${NC} nginx install failed"; exit 1; }
  fi

  # Remove legacy fake-google config if present from a previous deployment
  rm -f /etc/nginx/sites-enabled/fake-google /etc/nginx/sites-available/fake-google

  mkdir -p "${WEB_ROOT}"

  cat > "${WEB_ROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>El Mundo - La información de referencia</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Georgia, serif; color: #1a1a1a; background: #f5f5f5; }

    #demo-banner {
      background: #c1121f; color: #fff; text-align: center;
      padding: 8px 16px; font-size: 13px; font-weight: bold; letter-spacing: .4px;
      font-family: arial, sans-serif;
    }

    header { background: #fff; border-bottom: 3px solid #c1121f; padding: 12px 24px; }
    .header-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .logo { font-size: 36px; font-weight: bold; color: #c1121f; letter-spacing: -1px; text-decoration: none; }
    .logo span { color: #1a1a1a; }
    .header-date { font-size: 12px; color: #666; font-family: arial, sans-serif; }

    nav { background: #c1121f; }
    nav ul { display: flex; list-style: none; overflow-x: auto; }
    nav ul li a {
      display: block; padding: 10px 16px; color: #fff; text-decoration: none;
      font-size: 13px; font-family: arial, sans-serif; font-weight: 600;
      letter-spacing: .3px; white-space: nowrap;
    }
    nav ul li a:hover { background: rgba(255,255,255,.15); }

    .container { max-width: 1100px; margin: 20px auto; padding: 0 16px; }
    .main-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; }

    .article {
      background: #fff; cursor: pointer; border: 1px solid #e0e0e0;
      transition: box-shadow .2s;
    }
    .article:hover { box-shadow: 0 2px 8px rgba(0,0,0,.12); }

    .article-img-placeholder {
      width: 100%; height: 160px;
      display: flex; align-items: center; justify-content: center; font-size: 48px;
    }
    .article-body { padding: 12px 14px 16px; }
    .article-section {
      font-size: 11px; font-weight: bold; color: #c1121f;
      font-family: arial, sans-serif; letter-spacing: .5px;
      text-transform: uppercase; margin-bottom: 6px;
    }
    .article-title { font-size: 17px; font-weight: bold; line-height: 1.35; color: #1a1a1a; margin-bottom: 8px; }
    .article-summary { font-size: 13px; color: #555; line-height: 1.5; font-family: arial, sans-serif; }

    .article.featured { grid-column: 1 / -1; display: grid; grid-template-columns: 1.6fr 1fr; }
    .article.featured .article-img-placeholder { height: 100%; min-height: 240px; }
    .article.featured .article-title { font-size: 22px; }

    #captured {
      display: none; position: fixed; inset: 0;
      background: rgba(0,0,0,.75); z-index: 999;
      align-items: center; justify-content: center;
    }
    #captured.show { display: flex; }
    #cap-box {
      background: #fff; border-radius: 8px; padding: 36px 44px;
      max-width: 540px; width: 90%; text-align: center;
      box-shadow: 0 4px 32px rgba(0,0,0,.4);
    }
    #cap-box h2 { color: #c1121f; font-size: 22px; margin-bottom: 14px; }
    .cap-url {
      font-size: 14px; font-weight: bold; color: #1a1a1a; margin: 14px 0;
      background: #f5f5f5; padding: 10px 20px; border-radius: 4px;
      font-family: monospace; word-break: break-all;
    }
    #cap-box p { color: #555; font-size: 14px; line-height: 1.7; font-family: arial, sans-serif; }
    #cap-box button {
      margin-top: 22px; background: #c1121f; color: #fff;
      border: none; padding: 10px 28px; border-radius: 4px;
      font-size: 14px; cursor: pointer; font-family: arial, sans-serif;
    }

    footer {
      background: #1a1a1a; color: #aaa; text-align: center;
      padding: 20px; font-size: 12px; font-family: arial, sans-serif; margin-top: 32px;
    }
    footer a { color: #aaa; text-decoration: none; margin: 0 10px; }
    footer a:hover { color: #fff; }
    .footer-copy { margin-top: 8px; }
  </style>
</head>
<body>

<div id="demo-banner">
  &#9888; DEMO — DNS SPOOFING ACTIVO — Esta no es la página real de El Mundo &#9888;
</div>

<header>
  <div class="header-top">
    <a class="logo" href="#">El <span>Mundo</span></a>
    <div class="header-date" id="hdate"></div>
  </div>
</header>

<nav>
  <ul>
    <li><a href="#">España</a></li>
    <li><a href="#">Internacional</a></li>
    <li><a href="#">Economía</a></li>
    <li><a href="#">Tecnología</a></li>
    <li><a href="#">Deportes</a></li>
    <li><a href="#">Cultura</a></li>
    <li><a href="#">Salud</a></li>
    <li><a href="#">Motor</a></li>
  </ul>
</nav>

<div class="container">
  <div class="main-grid">

    <div class="article featured" onclick="showModal('elmundo.es/espana/2026/ciberseguridad-nacional.html')">
      <div class="article-img-placeholder" style="background:#c1121f; color:#fff; font-size:80px;">🗞</div>
      <div class="article-body">
        <div class="article-section">España</div>
        <div class="article-title">El Congreso aprueba la nueva ley de ciberseguridad con apoyo de todos los grupos parlamentarios</div>
        <div class="article-summary">La norma obliga a las empresas críticas a notificar brechas de seguridad en menos de 72 horas y establece un nuevo organismo supervisor dependiente del CNI.</div>
      </div>
    </div>

    <div class="article" onclick="showModal('elmundo.es/tecnologia/2026/wifi-publica-riesgos.html')">
      <div class="article-img-placeholder" style="background:#e8f4fd;">📡</div>
      <div class="article-body">
        <div class="article-section">Tecnología</div>
        <div class="article-title">Los expertos alertan: usar WiFi pública sin VPN expone tus datos bancarios</div>
        <div class="article-summary">El 40% de las redes WiFi abiertas en aeropuertos y hoteles interceptan tráfico sin cifrar, según un nuevo estudio.</div>
      </div>
    </div>

    <div class="article" onclick="showModal('elmundo.es/economia/2026/ibex-mercados.html')">
      <div class="article-img-placeholder" style="background:#e8f5e9;">📈</div>
      <div class="article-body">
        <div class="article-section">Economía</div>
        <div class="article-title">El Ibex 35 cierra con ganancias del 1,3% impulsado por el sector bancario</div>
        <div class="article-summary">Los valores financieros lideran las subidas tras los buenos datos de inflación publicados por el INE.</div>
      </div>
    </div>

    <div class="article" onclick="showModal('elmundo.es/deportes/2026/champions-final.html')">
      <div class="article-img-placeholder" style="background:#fff8e1;">⚽</div>
      <div class="article-body">
        <div class="article-section">Deportes</div>
        <div class="article-title">El Real Madrid remonta en el descuento y sella su pase a la final de Champions</div>
        <div class="article-summary">Un doblete en los últimos diez minutos da la vuelta al marcador ante el Bayern en el Bernabéu.</div>
      </div>
    </div>

  </div>
</div>

<div id="captured">
  <div id="cap-box">
    <h2>&#127907; Acceso interceptado</h2>
    <div class="cap-url" id="cap-url"></div>
    <p>
      El operador de la red manipuló el DNS y redirigió <strong>elmundo.es</strong>
      a esta página local.<br><br>
      Tu dispositivo nunca llegó al servidor real de El Mundo. La petición fue
      interceptada antes de salir de la red WiFi.<br><br>
      En un ataque real, esta página sería idéntica sin el banner de aviso,
      y cualquier credencial introducida quedaría registrada.
    </p>
    <button onclick="closeModal()">Cerrar</button>
  </div>
</div>

<footer>
  <div>
    <a href="#">Política de privacidad</a>
    <a href="#">Aviso legal</a>
    <a href="#">Publicidad</a>
    <a href="#">Contacto</a>
  </div>
  <div class="footer-copy">© 2026 Unidad Editorial Información General S.L.U.</div>
</footer>

<script>
  var d = new Date();
  var days = ['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
  var months = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
                'septiembre','octubre','noviembre','diciembre'];
  document.getElementById('hdate').textContent =
    days[d.getDay()] + ', ' + d.getDate() + ' de ' + months[d.getMonth()] + ' de ' + d.getFullYear();

  function showModal(url) {
    document.getElementById('cap-url').textContent = url;
    document.getElementById('captured').classList.add('show');
  }
  function closeModal() {
    document.getElementById('captured').classList.remove('show');
  }
</script>
</body>
</html>
HTML

  # Self-signed cert for the HTTPS→HTTP redirect server block
  mkdir -p /etc/nginx/ssl
  if [[ ! -f /etc/nginx/ssl/spoof.crt ]]; then
    openssl req -x509 -newkey rsa:2048 -days 825 -nodes \
      -keyout /etc/nginx/ssl/spoof.key \
      -out    /etc/nginx/ssl/spoof.crt \
      -subj   "/CN=${LAB_GATEWAY}/O=Lab/C=ES" 2>/dev/null
    chmod 600 /etc/nginx/ssl/spoof.key
  fi

  cat > "${NGINX_CONF}" <<NGINX
server {
    listen 80 default_server;
    root ${WEB_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}

server {
    listen 443 ssl default_server;
    ssl_certificate     /etc/nginx/ssl/spoof.crt;
    ssl_certificate_key /etc/nginx/ssl/spoof.key;
    return 301 http://\$host\$request_uri;
}
NGINX

  ln -sf "${NGINX_CONF}" "${NGINX_ENABLED}"
  rm -f /etc/nginx/sites-enabled/default
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

spoof_active() {
  [[ -f "${DNSMASQ_CONF}" ]]
}

# ---------------------------------------------------------------------------
# Enable / Disable
# ---------------------------------------------------------------------------

enable_spoof() {
  if spoof_active; then
    echo -e "${YELLOW}[--]${NC} DNS spoof already active"
    return
  fi

  write_assets

  # lab_webserver and nginx share port 80 — stop webserver first
  if systemctl is-active --quiet lab-webserver.service 2>/dev/null; then
    systemctl stop lab-webserver.service
    echo "[+] Stopped lab-webserver (port 80 now free)"
  fi

  # dnsmasq: address=/domain/IP matches the domain and all subdomains
  echo "address=/${SPOOF_DOMAIN}/${LAB_GATEWAY}" > "${DNSMASQ_CONF}"
  systemctl restart dnsmasq

  systemctl start nginx

  echo -e "${GREEN}[ON]${NC}  DNS spoof enabled — *.${SPOOF_DOMAIN} → ${LAB_GATEWAY}"
}

disable_spoof() {
  if ! spoof_active; then
    echo -e "${YELLOW}[--]${NC} DNS spoof already off"
    return
  fi

  systemctl stop nginx 2>/dev/null || true

  rm -f "${DNSMASQ_CONF}"
  systemctl restart dnsmasq

  echo -e "${YELLOW}[OFF]${NC} DNS spoof disabled — ${SPOOF_DOMAIN} resolves normally"
}

print_status() {
  echo
  echo -e "${CYAN}[+] DNS Spoof Exercise${NC}"
  if spoof_active; then
    echo -e "${GREEN}[ON] ${NC} dnsmasq : *.${SPOOF_DOMAIN} → ${LAB_GATEWAY}"
    systemctl is-active --quiet nginx \
      && echo -e "${GREEN}[ON] ${NC} nginx   : serving fake ${SPOOF_DOMAIN} on port 80" \
      || echo -e "${RED}[DOWN]${NC} nginx   : not running — check: systemctl status nginx"
  else
    echo -e "${YELLOW}[OFF]${NC} No DNS spoof active — ${SPOOF_DOMAIN} resolves normally"
  fi
  echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-status}"

case "${CMD}" in
  enable)  enable_spoof;  print_status ;;
  disable) disable_spoof; print_status ;;
  status)  print_status ;;
  *)
    echo "Usage: sudo $0 {enable|disable|status}"
    echo
    echo "  enable    Start exercise: ${SPOOF_DOMAIN} → fake local page via nginx"
    echo "  disable   Stop exercise (default state)"
    echo "  status    Show current state"
    echo
    echo "  Override domain:  sudo SPOOF_DOMAIN=google.com $0 enable"
    echo
    echo "  Note: nginx and lab_webserver share port 80 — only one runs at a time."
    exit 1
    ;;
esac
