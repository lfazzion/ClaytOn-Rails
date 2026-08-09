#!/usr/bin/env python3
# PageFetchTool Python fallback: busca URL arbitrária via nodriver (stealth).
# Invocado por `ScrapingServices::NodriverRunner.fetch_page` quando o host
# está em `config/hard_domains.yml`. Saída: JSON em stdout.

import asyncio
import json
import argparse
import sys

try:
    import nodriver as uc
except ImportError:
    print(json.dumps({"error": "nodriver not installed"}), file=sys.stderr)
    sys.exit(1)

import browser_binary


async def fetch(url, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    try:
        page = await browser.get(url)
        await asyncio.sleep(3)
        html = await page.get_content()
        title = await page.evaluate("document.title")
        body_text = await page.evaluate(
            "document.body ? document.body.innerText.substring(0, 20000) : ''"
        )
        current_url = await page.evaluate("window.location.href")

        return {
            "title": title or "",
            "url": current_url or url,
            "content": body_text or "",
            "html_bytes": len(html.encode("utf-8")) if html else 0,
        }
    finally:
        try:
            browser.stop()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--proxy", default=None)
    args = parser.parse_args()

    try:
        result = asyncio.run(fetch(args.url, proxy=args.proxy))
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
