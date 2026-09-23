# python/hmac_utils.py
import hashlib
import hmac
from typing import Optional


def compute_hmac_signature(secret: str, body: bytes) -> str:
    """
    Вычисляет HMAC-SHA256 подпись над точными UTF-8 body bytes.
    
    Ключом являются точные UTF-8 bytes без trim/Base64/hex.
    """
    secret_bytes = secret.encode("utf-8")
    signature = hmac.new(secret_bytes, body, hashlib.sha256).hexdigest()
    return f"v1={signature}"


def verify_hmac_signature(secret: str, body: bytes, signature_header: str) -> bool:
    """Проверяет HMAC подпись constant-time."""
    if not signature_header.startswith("v1="):
        return False
    
    expected = compute_hmac_signature(secret, body)
    provided = signature_header
    
    # constant-time сравнение
    return hmac.compare_digest(expected.encode(), provided.encode())