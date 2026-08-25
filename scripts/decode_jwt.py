#!/usr/bin/env python3
"""Decode a JWT for local debugging without committing real tokens.

Usage:
    python3 scripts/decode_jwt.py <token>

The token is passed as an argument so no real credential is ever embedded
in the source tree. Only the header and payload are decoded; the signature
is intentionally ignored.
"""

from __future__ import annotations

import base64
import json
import sys


def _b64url_decode(data: str) -> bytes:
    padding = "=" * ((4 - len(data) % 4) % 4)
    return base64.urlsafe_b64decode(data + padding)


def decode_jwt(token: str) -> None:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Geçersiz JWT formatı: üç nokta ile ayrılmış bölüm bekleniyor.")

    header = json.loads(_b64url_decode(parts[0]).decode("utf-8"))
    payload = json.loads(_b64url_decode(parts[1]).decode("utf-8"))

    print("--- HEADER ---")
    print(json.dumps(header, indent=2))
    print("\n--- PAYLOAD ---")
    print(json.dumps(payload, indent=2))


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/decode_jwt.py <token>", file=sys.stderr)
        return 2
    try:
        decode_jwt(sys.argv[1])
        return 0
    except Exception as exc:
        print(f"Hata: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
