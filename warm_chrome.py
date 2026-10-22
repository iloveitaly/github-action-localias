"""
curl and chrome use different certificate stores.

'Warming' the curl certificate store by requesting the URL does not warm the certs for Chrome.

This seems insane that we need to do this, there must be some more deterministic way of handling this, but I could
not find a better solution and this works pretty reliably.
"""

import os
import sys
import time
from playwright.sync_api import sync_playwright


def normalize_url(url: str):
    "the URLs from localias do not have a scheme, so we need to add one"

    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    return url


def resolve_ws_endpoint(raw_value: str | None) -> str | None:
    if not raw_value:
        return None
    stripped = raw_value.strip()
    if stripped.lower() in ("", "true", "false"):
        return None
    return stripped


def connect_or_launch(playwright, ws_endpoint: str | None):
    if not ws_endpoint:
        return playwright.chromium.launch()
    # Standard Chrome DevTools Protocol endpoints typically contain /devtools/
    # or use http(s):// host:port discovery. Playwright server endpoints do not.
    if "/devtools/" in ws_endpoint or ws_endpoint.startswith(("http://", "https://")):
        return playwright.chromium.connect_over_cdp(ws_endpoint)
    try:
        return playwright.chromium.connect_over_cdp(ws_endpoint)
    except Exception:
        return playwright.chromium.connect(ws_endpoint)


def visit_with_retries(url, ws_endpoint=None, max_retries=5):
    url = normalize_url(url)

    for attempt in range(max_retries):
        try:
            with sync_playwright() as p:
                browser = connect_or_launch(p, ws_endpoint)
                try:
                    context = browser.new_context()
                    page = context.new_page()
                    try:
                        page.goto(url)
                    finally:
                        page.close()
                        context.close()
                finally:
                    browser.close()
                return True
        except Exception as e:
            print(f"Attempt {attempt + 1}/{max_retries} failed: {str(e)}")
            if attempt < max_retries - 1:
                time.sleep(2)
                continue
            raise


if __name__ == "__main__":
    ws_arg = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("WARM_CHROME")
    visit_with_retries(sys.argv[1], resolve_ws_endpoint(ws_arg))
