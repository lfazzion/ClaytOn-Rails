#!/usr/bin/env python3

import sys
import json
import argparse

try:
    from curl_cffi import requests
except ImportError:
    print(json.dumps({"error": "curl_cffi not installed"}), file=sys.stderr)
    sys.exit(1)


# curl_cffi >= 0.8 dobrou a versão dentro do próprio token de impersonate e
# removeu o kwarg `impersonate_version` — passá-lo levanta TypeError em
# Session.request().
IMPERSONATE_PROFILES = {
    "chrome": {
        "impersonate": "chrome131",
    },
    "safari": {
        "impersonate": "safari180",
    },
    "firefox": {
        "impersonate": "firefox135",
    },
    "chrome_android": {
        "impersonate": "chrome131_android",
        "extra_headers": {
            "Sec-Ch-Ua-Mobile": "?1",
            "Sec-Ch-Ua-Platform": '"Android"',
        },
    },
    "edge": {
        "impersonate": "edge101",
    },
}


def build_fingerprint(profile_name):
    profile = IMPERSONATE_PROFILES.get(profile_name, IMPERSONATE_PROFILES["chrome"])
    return profile


def do_request(url, method="GET", profile="chrome", proxy=None, headers=None, body=None, timeout=30):
    fp = build_fingerprint(profile)

    kwargs = {
        "impersonate": fp["impersonate"],
        "timeout": timeout,
    }

    if proxy:
        kwargs["proxy"] = proxy

    merged_headers = {}
    if fp.get("extra_headers"):
        merged_headers.update(fp["extra_headers"])
    if headers:
        merged_headers.update(headers)
    if merged_headers:
        kwargs["headers"] = merged_headers

    if body and method.upper() == "POST":
        kwargs["data"] = body

    try:
        resp = requests.request(method, url, **kwargs)

        if resp.status_code == 429:
            return {
                "success": False,
                "error": "rate_limit_429",
                "status_code": resp.status_code,
                "body": resp.text[:500],
            }

        if resp.status_code == 403:
            return {
                "success": False,
                "error": "blocked_403",
                "status_code": resp.status_code,
                "body": resp.text[:500],
            }

        if resp.status_code == 503:
            return {
                "success": False,
                "error": "unavailable_503",
                "status_code": resp.status_code,
                "body": resp.text[:500],
            }

        return {
            "success": True,
            "status_code": resp.status_code,
            "body": resp.text,
            "url": resp.url,
            "headers": dict(resp.headers),
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": 0,
        }


def main():
    parser = argparse.ArgumentParser(description="HTTP client with TLS fingerprint impersonation via curl_cffi")
    parser.add_argument("url", help="Target URL")
    parser.add_argument("--method", default="GET", choices=["GET", "POST"])
    parser.add_argument("--profile", default="chrome", choices=list(IMPERSONATE_PROFILES.keys()))
    parser.add_argument("--proxy", default=None)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--body", default=None)
    parser.add_argument("--header", action="append", help="Extra headers in Key:Value format")

    args = parser.parse_args()

    extra_headers = {}
    if args.header:
        for h in args.header:
            if ":" in h:
                key, val = h.split(":", 1)
                extra_headers[key.strip()] = val.strip()

    result = do_request(
        url=args.url,
        method=args.method,
        profile=args.profile,
        proxy=args.proxy,
        headers=extra_headers if extra_headers else None,
        body=args.body,
        timeout=args.timeout,
    )

    print(json.dumps(result))


if __name__ == "__main__":
    main()
