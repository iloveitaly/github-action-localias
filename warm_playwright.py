import sys
import time
from playwright.sync_api import sync_playwright


def normalize_url(url: str):
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
