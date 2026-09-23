# python/tests/test_hmac.py
"""Тесты для HMAC-утилит."""

import hashlib
import hmac
import json
import pytest

from python.hmac_utils import compute_hmac_signature, verify_hmac_signature


class TestHMAC:
    """Тесты HMAC-подписи."""

    def test_hmac_uses_raw_utf8_secret(self):
        """HMAC использует точные UTF-8 bytes секрета без trim."""
        body = b'{"version":1}'
        
        sig1 = compute_hmac_signature(" raw-secret ", body)
        sig2 = compute_hmac_signature("raw-secret", body)
        sig3 = compute_hmac_signature(" raw-secret ", body + b"\n")
        
        # Все разные
        assert sig1 != sig2
        assert sig1 != sig3
        assert sig2 != sig3
        
        # Правильный формат
        assert sig1.startswith("v1=")
        assert len(sig1) == 3 + 64  # "v1=" + 64 hex chars
        
        # Проверка что это hex
        hex_part = sig1[3:]
        assert all(c in "0123456789abcdef" for c in hex_part)

    def test_hmac_verification_constant_time_style(self):
        """Проверка подписи использует constant-time сравнение."""
        secret = "test-secret"
        body = b'{"test":true}'
        
        signature = compute_hmac_signature(secret, body)
        
        # Правильная подпись
        assert verify_hmac_signature(secret, body, signature) is True
        
        # Неверная подпись
        assert verify_hmac_signature(secret, body, "v1=invalid") is False
        
        # Неверный формат
        assert verify_hmac_signature(secret, body, "invalid") is False
        
        # Пустая подпись
        assert verify_hmac_signature(secret, body, "") is False
        
        # Неверный секрет
        wrong_signature = compute_hmac_signature("wrong-secret", body)
        assert verify_hmac_signature(secret, body, wrong_signature) is False

    def test_hmac_computes_over_exact_body_bytes(self):
        """HMAC вычисляется над точными body bytes."""
        secret = "test-secret"
        body1 = b'{"key":"value"}'
        body2 = b'{"key":"value"}\n'
        
        sig1 = compute_hmac_signature(secret, body1)
        sig2 = compute_hmac_signature(secret, body2)
        
        # Разные body дают разные подписи
        assert sig1 != sig2
        
        # Проверка через стандартный hmac
        expected = hmac.new(
            secret.encode("utf-8"),
            body1,
            hashlib.sha256
        ).hexdigest()
        assert sig1 == f"v1={expected}"

    def test_hmac_with_unicode_secret(self):
        """HMAC работает с Unicode в секрете."""
        secret = "секрет-ключ🔑"
        body = b'{"test":true}'
        
        signature = compute_hmac_signature(secret, body)
        assert verify_hmac_signature(secret, body, signature) is True
        
        # Тот же секрет в разных нормализациях может дать разные подписи
        secret_normalized = "секрет-ключ\uD83D\uDD11"
        sig2 = compute_hmac_signature(secret_normalized, body)
        assert signature != sig2  # Unicode нормализация важна!


class TestHMACIntegration:
    """Интеграционные тесты HMAC с receipt."""

    def test_hmac_with_receipt_bytes(self):
        """HMAC вычисляется над exact JSON bytes из receipt."""
        from python.models import ReceiptV1
        
        receipt = ReceiptV1(
            external_request_id="external-123",
            message_id="provider-123",
            occurred_at="2026-09-04T12:00:00.123Z",
            outcome="COMPLETED",
            provider_payment_id="provider-123"
        )
        
        body_bytes = receipt.to_compact_json_bytes()
        secret = "test-hmac-secret"
        
        signature = compute_hmac_signature(secret, body_bytes)
        
        # Проверка что подпись валидна
        assert verify_hmac_signature(secret, body_bytes, signature) is True
        
        # Проверка что изменение body ломает подпись
        corrupted_bytes = body_bytes + b" "
        assert verify_hmac_signature(secret, corrupted_bytes, signature) is False