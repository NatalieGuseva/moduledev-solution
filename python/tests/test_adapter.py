# python/tests/test_adapter.py
"""Тесты для receipt-adapter."""

import json
import pytest
from unittest.mock import AsyncMock, Mock, patch
from aiohttp import web, ClientResponse, ClientSession

from python.receipt_adapter import ReceiptAdapter
from python.config import AdapterConfig
from python.models import ProviderCallback, ReceiptV1


def make_request(body, capability="test-capability"):
    """Мок aiohttp-запроса: тело отдаётся потоково через request.content.iter_chunked,
    как в реальном адаптере (без Content-Length — chunked-сценарий)."""
    raw = body if isinstance(body, bytes) else body.encode("utf-8")

    async def iter_chunked(size):
        for i in range(0, len(raw), size):
            yield raw[i:i + size]

    request = Mock()
    request.match_info = {"capability": capability}
    request.content = Mock()
    request.content.iter_chunked = iter_chunked
    return request


class TestProviderCallback:
    """Тесты парсинга legacy callback."""

    def test_valid_callback_parsing(self):
        """Парсинг валидного callback."""
        data = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        
        callback = ProviderCallback.from_dict(data)
        
        assert callback.provider_payment_id == "provider-123"
        assert callback.operation_id == "external-123"
        assert callback.result == "COMPLETED"
        assert callback.message == "Payment completed"
        assert callback.occurred_at == "2026-09-04T12:00:00Z"

    def test_callback_rejects_unknown_fields(self):
        """Callback с неизвестными полями отклоняется."""
        data = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z",
            "unknownField": "should_fail"
        }
        
        with pytest.raises(ValueError, match="Unknown fields"):
            ProviderCallback.from_dict(data)

    def test_callback_rejects_crlf_in_fields(self):
        """Callback с CR/LF в полях отклоняется."""
        base = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        
        # Проверяем каждое поле
        for field in ("providerPaymentId", "operationId", "occurredAt", "message"):
            data = base.copy()
            data[field] = f"value\r\nwith_crlf"
            
            with pytest.raises(ValueError, match="CR/LF"):
                ProviderCallback.from_dict(data)


class TestReceiptConversion:
    """Тесты преобразования legacy callback в receipt v1."""

    def test_legacy_to_receipt_mapping(self):
        """Маппинг всех полей legacy callback -> receipt v1."""
        legacy = {
            "providerPaymentId": "provider-456",
            "operationId": "external-789",
            "result": "REJECTED",
            "message": "Payment rejected",
            "occurredAt": "2026-09-05T15:30:45.123Z"
        }
        
        callback = ProviderCallback.from_dict(legacy)
        receipt = ReceiptV1.from_legacy(callback)
        
        # Проверка маппинга согласно контракту
        assert receipt.message_id == "provider-456"  # providerPaymentId -> messageId
        assert receipt.external_request_id == "external-789"  # operationId -> externalRequestId
        assert receipt.outcome == "REJECTED"  # result -> outcome
        assert receipt.provider_payment_id == "provider-456"  # providerPaymentId -> providerPaymentId
        assert receipt.occurred_at == "2026-09-05T15:30:45.123Z"  # raw string preserved
        assert receipt.version == 1  # всегда 1

    def test_legacy_callback_discards_message(self):
        """Поле message валидируется и отбрасывается."""
        legacy = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "This message should be discarded",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        
        callback = ProviderCallback.from_dict(legacy)
        receipt = ReceiptV1.from_legacy(callback)
        
        # message не должен попасть в receipt
        receipt_dict = json.loads(receipt.to_compact_json_bytes())
        assert "message" not in receipt_dict

    def test_receipt_exact_json_bytes(self):
        """Receipt сериализуется в exact compact JSON bytes."""
        receipt = ReceiptV1(
            external_request_id="external-123",
            message_id="provider-123",
            occurred_at="2026-09-04T12:00:00.123Z",
            outcome="COMPLETED",
            provider_payment_id="provider-123"
        )
        
        bytes_result = receipt.to_compact_json_bytes()
        
        # Ожидаемый JSON с sort_keys=True, separators=(',', ':'), без LF
        expected = (
            b'{"externalRequestId":"external-123",'
            b'"messageId":"provider-123",'
            b'"occurredAt":"2026-09-04T12:00:00.123Z",'
            b'"outcome":"COMPLETED",'
            b'"providerPaymentId":"provider-123",'
            b'"version":1}'
        )
        
        assert bytes_result == expected
        assert not bytes_result.endswith(b"\n")  # Без завершающего LF
        assert b" " not in bytes_result  # Без пробелов

    def test_receipt_compact_serialization_roundtrip(self):
        """Round-trip сериализация/десериализация."""
        receipt = ReceiptV1(
            external_request_id="test-123",
            message_id="msg-456",
            occurred_at="2026-09-04T12:00:00Z",
            outcome="COMPLETED",
            provider_payment_id="provider-456"
        )
        
        bytes_result = receipt.to_compact_json_bytes()
        decoded = json.loads(bytes_result)
        
        assert decoded["externalRequestId"] == "test-123"
        assert decoded["messageId"] == "msg-456"
        assert decoded["occurredAt"] == "2026-09-04T12:00:00Z"
        assert decoded["outcome"] == "COMPLETED"
        assert decoded["providerPaymentId"] == "provider-456"
        assert decoded["version"] == 1


class TestReceiptAdapter:
    """Тесты HTTP-адаптера."""

    @pytest.fixture
    def adapter_config(self):
        """Фикстура конфигурации адаптера."""
        return AdapterConfig(
            capability="test-capability",
            token="test-token",
            hmac_secret="test-hmac-secret",
            receipt_api_url="http://gateway:8080/api/receipt/accept",
            max_body_size=64 * 1024
        )

    @pytest.fixture
    def adapter(self, adapter_config):
        """Фикстура адаптера."""
        return ReceiptAdapter(adapter_config)

    @pytest.mark.asyncio
    async def test_adapter_rejects_wrong_capability(self, adapter):
        """Неверный capability возвращает 404."""
        request = Mock()
        request.match_info = {"capability": "wrong-capability"}
        request.content_length = 0
        
        response = await adapter._handle_callback(request)
        assert response.status == 404

    @pytest.mark.asyncio
    async def test_adapter_rejects_invalid_json(self, adapter):
        """Невалидный JSON возвращает 400."""
        request = make_request("invalid json")
        
        response = await adapter._handle_callback(request)
        assert response.status == 400

    @pytest.mark.asyncio
    async def test_adapter_rejects_large_body(self, adapter, adapter_config):
        """Тело больше лимита возвращает 400."""
        request = make_request(b"x" * (adapter_config.max_body_size + 1))
        
        response = await adapter._handle_callback(request)
        assert response.status == 400

    @pytest.mark.asyncio
    async def test_adapter_successful_callback(self, adapter):
        """Успешная обработка callback."""
        # Подготовка запроса
        valid_callback = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        request = make_request(json.dumps(valid_callback))
        
        # Мокаем отправку в gateway
        gateway_result = (200, '{"status":"ok","outcome":"RECEIVED"}')
        
        with patch.object(adapter, '_send_to_gateway', AsyncMock(return_value=gateway_result)):
            response = await adapter._handle_callback(request)
            
            assert response.status == 200
            assert "status" in response.text

    @pytest.mark.asyncio
    async def test_adapter_gateway_timeout(self, adapter):
        """Таймаут gateway возвращает 503."""
        valid_callback = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        request = make_request(json.dumps(valid_callback))
        
        # Мокаем ошибку отправки
        with patch.object(adapter, '_send_to_gateway', AsyncMock(side_effect=Exception("Connection timeout"))):
            response = await adapter._handle_callback(request)
            
            assert response.status == 503
            body = json.loads(response.text)
            assert body["code"] == "dependency.unavailable"

    @pytest.mark.asyncio
    async def test_adapter_validates_callback_schema(self, adapter):
        """Валидация schema callback."""
        # Невалидный callback (отсутствует обязательное поле)
        invalid_callback = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            # отсутствует "result"
            "message": "Payment completed",
            "occurredAt": "2026-09-04T12:00:00Z"
        }
        request = make_request(json.dumps(invalid_callback))
        
        response = await adapter._handle_callback(request)
        assert response.status == 400

    @pytest.mark.asyncio
    async def test_adapter_rejects_missing_message(self, adapter):
        """message обязателен в legacy callback (фидбэк недели 3)."""
        body = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "occurredAt": "2026-09-04T12:00:00Z",
        }
        response = await adapter._handle_callback(make_request(json.dumps(body)))
        assert response.status == 400

    @pytest.mark.asyncio
    async def test_adapter_logs_do_not_contain_body_or_signature(self, adapter, caplog):
        """В логах нет тела квитанции и HMAC-signature (фидбэк недели 3, high)."""
        import logging
        marker = "MARKER-SECRET-MESSAGE-0451"
        callback = {
            "providerPaymentId": "provider-123",
            "operationId": "external-123",
            "result": "COMPLETED",
            "message": marker,
            "occurredAt": "2026-09-04T12:00:00Z",
        }
        seen = {}

        async def fake_send(receipt, body_bytes, signature):
            seen["signature"] = signature
            seen["body"] = body_bytes.decode("utf-8")
            return 200, '{"status":"ok"}'

        with caplog.at_level(logging.DEBUG):
            with patch.object(adapter, "_send_to_gateway", fake_send):
                response = await adapter._handle_callback(make_request(json.dumps(callback)))

        assert response.status == 200
        logged = "\n".join(str(r.msg) + " " + r.getMessage() for r in caplog.records)
        assert marker not in logged
        assert seen["signature"] not in logged
        assert seen["body"] not in logged
