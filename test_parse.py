#!/usr/bin/env python3
"""Quick smoke-test for the OmniParser /parse/ endpoint (stdlib only)."""

import base64
import json
import sys
import time
import urllib.request
from pathlib import Path

SERVER = "http://10.4.139.26:8000"
IMAGE_PATH = Path("imgs/emis_image_test.png")


def get_json(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read())


def post_json(url, payload, timeout=300):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def main():
    image_path = Path(sys.argv[1]) if len(sys.argv) > 1 else IMAGE_PATH

    # Health check
    print(f"[1/3] Pinging {SERVER}/health/ ...")
    resp = get_json(f"{SERVER}/health/")
    print(f"       OK – {resp}")

    # Encode image
    print(f"[2/3] Encoding {image_path} ...")
    image_bytes = image_path.read_bytes()
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    print(
        f"       Image size: {len(image_bytes) / 1024:.1f} KB, base64 length: {len(b64)}"
    )

    # Call /parse/
    print(f"[3/3] POST {SERVER}/parse/ ...")
    start = time.time()
    result = post_json(f"{SERVER}/parse/", {"base64_image": b64})
    elapsed = time.time() - start

    print(
        f"       Done in {elapsed:.1f}s; server-side latency: {result['latency']:.1f}s"
    )
    print(f"       Response keys: {list(result.keys())}")
    # Pretty-print the full response
    full = json.dumps(result["parsed_content_list"], indent=2, default=str)
    print("\n===== Full Response =====")
    print(full)


if __name__ == "__main__":
    main()
