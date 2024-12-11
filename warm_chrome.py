"""
curl and chrome use different certificate stores.

'Warming' the curl certificate store by requesting the URL does not warm the certs for Chrome.

This seems insane that we need to do this, there must be some more deterministic way of handling this, but I could
not find a better solution and this works pretty reliably.
"""

import sys
import time
from playwright.sync_api import sync_playwright


def normalize_url(url: str):
    "the URLs from localias do not have a scheme, so we need to add one"

    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    return url


def visit_with_retries(url, max_retries=5):
    url = normalize_url(url)

    for attempt in range(max_retries):
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch()
                page = browser.new_page()
                page.goto(url)
                return True
        except Exception as e:
            print(f"Attempt {attempt + 1}/{max_retries} failed: {str(e)}")
            if attempt < max_retries - 1:
                time.sleep(2)
                continue
            raise


visit_with_retries(sys.argv[1])
