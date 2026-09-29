#!/usr/bin/env python3
"""Выпускает короткоживущий HS256 JWT для ручных запросов к gateway (runbook в README.md).

Читает COURSE_JWT_ISSUER / COURSE_JWT_AUDIENCE / COURSE_JWT_SIGNING_KEY из окружения
(те же значения, что в .env). Токен печатается в stdout и нигде не логируется и не сохраняется.

Пример:
  export $(grep -v '^#' .env | xargs)
  TOKEN=$(python3 scripts/issue_token.py --scope "diagnostics:read")
"""
import argparse, base64, hashlib, hmac, json, os, sys, time


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True, help="scope'ы через пробел, например 'diagnostics:read'")
    ap.add_argument("--sub", default="runbook-operator")
    ap.add_argument("--consumer", default="runbook")
    ap.add_argument("--ttl", type=int, default=300, help="секунды жизни токена")
    args = ap.parse_args()

    try:
        issuer = os.environ["COURSE_JWT_ISSUER"]
        audience = os.environ["COURSE_JWT_AUDIENCE"]
        key = os.environ["COURSE_JWT_SIGNING_KEY"].encode()
    except KeyError as e:
        print(f"нет переменной окружения {e.args[0]} (см. .env.example)", file=sys.stderr)
        return 2

    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"iss": issuer, "aud": audience, "sub": args.sub, "consumer": args.consumer,
               "scope": args.scope, "iat": now, "exp": now + args.ttl}
    signing_input = f"{b64(json.dumps(header, separators=(',', ':')).encode())}.{b64(json.dumps(payload, separators=(',', ':')).encode())}"
    sig = hmac.new(key, signing_input.encode(), hashlib.sha256).digest()
    print(f"{signing_input}.{b64(sig)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
