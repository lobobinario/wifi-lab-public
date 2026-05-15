#!/usr/bin/env python3
"""
Lab WiFi — Demo HTTP/HTTPS web server.
HTTP  → port 8880  (traffic visible in plaintext)
HTTPS → port 8443  (traffic encrypted)

Endpoints:
  GET  /send      — show submission form
  POST /send      — save entry, show confirmation
  GET  /visualize — table of all captured entries
  GET  /          — redirect to /visualize
"""
import json
import os
import ssl
import threading
from datetime import datetime
from html import escape
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LOG_FILE  = "/var/log/lab_webserver.log"
CERT_FILE = "/etc/lab-webserver/server.crt"
KEY_FILE  = "/etc/lab-webserver/server.key"
HTTP_PORT  = 80
HTTPS_PORT = 443

# ── data layer ────────────────────────────────────────────────────────────────

def append_log(proto, client_ip, user, message):
    entry = {
        "ts":      datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "proto":   proto,
        "ip":      client_ip,
        "user":    user[:20],
        "message": message[:50],
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def read_log():
    if not os.path.exists(LOG_FILE):
        return []
    out = []
    with open(LOG_FILE) as f:
        for line in f:
            try:
                out.append(json.loads(line.strip()))
            except (json.JSONDecodeError, ValueError):
                pass
    return out

# ── HTML templates ─────────────────────────────────────────────────────────────

_CSS = """
  body   { font-family: monospace; max-width: 460px; margin: 50px auto; padding: 20px }
  .banner{ padding: 12px; margin-bottom: 20px; border-radius: 4px; font-weight: bold }
  .http  { background: #f8d7da; color: #721c24 }
  .https { background: #d4edda; color: #155724 }
  input  { width: 100%; padding: 8px; margin: 6px 0 14px; box-sizing: border-box }
  button { padding: 10px 24px; background: #0062cc; color: #fff; border: none; cursor: pointer }
  a      { color: #555 }
"""

FORM_HTML = """\
<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Lab WiFi – Enviar mensaje</title>
<style>{css}</style></head><body>
<h2>Formulario de prueba</h2>
<div class="banner {cls}">{banner}</div>
<form method="POST" action="/send">
  <label>Usuario (máx 20 chars):</label>
  <input name="user" maxlength="20" required>
  <label>Mensaje (máx 50 chars):</label>
  <input name="message" maxlength="50" required>
  <button type="submit">Enviar</button>
</form>
<br>
<a href="{switch_url}">{switch_label}</a><br>
<a href="/visualize">Ver mensajes capturados →</a>
</body></html>"""

DONE_HTML = """\
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Enviado</title>
<style>body{{ font-family:monospace; max-width:460px; margin:50px auto; padding:20px }}</style>
</head><body>
<h2>Mensaje enviado</h2>
<p>Usuario: <b>{user}</b><br>Mensaje: <b>{message}</b></p>
<a href="/send">Enviar otro</a> &nbsp; <a href="/visualize">Ver tabla →</a>
</body></html>"""

VISUALIZE_HTML = """\
<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Lab WiFi – Mensajes capturados</title>
<style>
  body  {{ font-family: monospace; margin: 20px; font-size: 14px }}
  table {{ border-collapse: collapse; width: 100% }}
  th,td {{ border: 1px solid #ccc; padding: 8px }}
  th    {{ background: #f5f5f5 }}
  .HTTP  {{ color: #c0392b; font-weight: bold }}
  .HTTPS {{ color: #27ae60; font-weight: bold }}
</style></head><body>
<h2>Mensajes capturados ({n})</h2>
<table>
<tr><th>Timestamp</th><th>Proto</th><th>IP</th><th>Usuario</th><th>Mensaje</th></tr>
{rows}
</table>
<br><a href="/send">← Enviar mensaje</a>
<p style="color:#888;font-size:12px">Log: {log_file}</p>
</body></html>"""

# ── request handler ────────────────────────────────────────────────────────────

class LabHandler(BaseHTTPRequestHandler):
    proto = "HTTP"

    def log_message(self, fmt, *args):
        pass  # suppress default stdout log

    def reply(self, code, html):
        body = html.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def _host(self):
        return self.headers.get("Host", "").split(":")[0] or self.server.server_address[0]

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/send":
            host = self._host()
            if self.proto == "HTTPS":
                cls          = "https"
                banner       = "HTTPS — tu mensaje viaja CIFRADO (nadie puede leerlo en tránsito)"
                switch_url   = f"http://{host}/send"
                switch_label = "← Enviar via HTTP (sin cifrado)"
            else:
                cls          = "http"
                banner       = "HTTP — tu mensaje viaja en TEXTO CLARO ¡visible con Wireshark o tcpdump!"
                switch_url   = f"https://{host}/send"
                switch_label = "→ Enviar via HTTPS (cifrado)"
            self.reply(200, FORM_HTML.format(
                css=_CSS, cls=cls, banner=banner,
                switch_url=switch_url, switch_label=switch_label,
            ))

        elif path in ("/", "/visualize"):
            entries = read_log()
            rows = "".join(
                '<tr><td>{ts}</td>'
                '<td class="{p}">{p}</td>'
                '<td>{ip}</td><td>{u}</td><td>{m}</td></tr>'.format(
                    ts=escape(e.get("ts", "")),
                    p=escape(e.get("proto", "")),
                    ip=escape(e.get("ip", "")),
                    u=escape(e.get("user", "")),
                    m=escape(e.get("message", "")),
                )
                for e in reversed(entries)
            )
            self.reply(200, VISUALIZE_HTML.format(
                n=len(entries),
                rows=rows or '<tr><td colspan="5" style="text-align:center">Sin datos aún</td></tr>',
                log_file=LOG_FILE,
            ))
        else:
            self.redirect("/visualize")

    def do_POST(self):
        if urlparse(self.path).path != "/send":
            self.send_response(404)
            self.end_headers()
            return
        length  = int(self.headers.get("Content-Length", 0))
        body    = self.rfile.read(length).decode("utf-8", errors="replace")
        params  = parse_qs(body)
        user    = params.get("user",    [""])[0][:20].strip()
        message = params.get("message", [""])[0][:50].strip()
        append_log(self.proto, self.client_address[0], user, message)
        self.reply(200, DONE_HTML.format(user=escape(user), message=escape(message)))


class LabHandlerHTTPS(LabHandler):
    proto = "HTTPS"

# ── server bootstrap ───────────────────────────────────────────────────────────

def _serve(port, handler_cls, tls=False):
    server = HTTPServer(("0.0.0.0", port), handler_cls)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
    proto = "HTTPS" if tls else "HTTP"
    print(f"[lab-webserver] {proto} listening on port {port}")
    server.serve_forever()


if __name__ == "__main__":
    threading.Thread(
        target=_serve, args=(HTTP_PORT, LabHandler), daemon=True
    ).start()
    _serve(HTTPS_PORT, LabHandlerHTTPS, tls=True)
