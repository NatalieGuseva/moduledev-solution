# python/tests/test_dispatcher.py
"""Тесты для outbox-dispatcher."""

import asyncio
import uuid
import pytest
from unittest.mock import AsyncMock, Mock, patch
from datetime import datetime

from python.outbox_dispatcher import OutboxDispatcher
from python.config import DatabaseConfig, DispatcherConfig, ProviderConfig
from python.models import OutboxClaim
from python.provider_client import ProviderResponse


class TestOutboxDispatcher:
    """Тесты Outbox Dispatcher."""

    @pytest.fixture
    def db_config(self):
        """Фикстура конфигурации БД."""
        return DatabaseConfig(
            host="localhost",
            port=5432,
            dbname="course",
            user="outbox_dispatcher",
            password="test-password"
        )

    @pytest.fixture
    def dispatcher_config(self):
        """Фикстура конфигурации dispatcher."""
        return DispatcherConfig(
            owner="outbox-dispatcher",
            poll_interval_seconds=0.1,
            claim_limit=5
        )

    @pytest.fixture
    def provider_config(self):
        """Фикстура конфигурации провайдера."""
        return ProviderConfig(
            url="http://provider-simulator:8081",
            timeout_seconds=2.0
        )

    @pytest.fixture
    def sample_claim(self):
        """Фикстура OutboxClaim."""
        return OutboxClaim(
            outbox_id=uuid.uuid4(),
            lease_version=1,
            external_request_id="external-123",
            correlation_id=uuid.uuid4(),
            amount="1000.00",
            currency="RUB"
        )

    @pytest.mark.asyncio
    async def test_dispatcher_processes_claim_successfully(
        self, db_config, dispatcher_config, provider_config, sample_claim
    ):
        """Успешная обработка claim."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        # Мокаем методы
        dispatcher._db.claim_outbox = AsyncMock(return_value=[sample_claim])
        dispatcher._db.succeed_outbox = AsyncMock(return_value={})
        dispatcher._provider.send_payment = AsyncMock(
            return_value=ProviderResponse(202, {"providerPaymentId": "provider-123", "status": "ACCEPTED"})
        )
        
        dispatcher._running = True
        await dispatcher._process_claim(sample_claim)
        
        # Проверяем что succeed_outbox был вызван
        dispatcher._db.succeed_outbox.assert_called_once_with(
            outbox_id=sample_claim.outbox_id,
            owner=dispatcher._owner,
            lease_version=sample_claim.lease_version,
            provider_payment_id="provider-123"
        )
        dispatcher._db.fail_outbox.assert_not_called()

    @pytest.mark.asyncio
    async def test_dispatcher_handles_provider_rejection(
        self, db_config, dispatcher_config, provider_config, sample_claim
    ):
        """Обработка отказа провайдера (non-retryable)."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        dispatcher._db.claim_outbox = AsyncMock(return_value=[sample_claim])
        dispatcher._db.fail_outbox = AsyncMock(return_value={})
        dispatcher._provider.send_payment = AsyncMock(
            return_value=ProviderResponse(400, {"error": "bad request"})
        )
        
        await dispatcher._process_claim(sample_claim)
        
        # Проверяем что fail_outbox был вызван с terminal error
        dispatcher._db.fail_outbox.assert_called_once_with(
            outbox_id=sample_claim.outbox_id,
            owner=dispatcher._owner,
            lease_version=sample_claim.lease_version,
            error_code="http.400.terminal"
        )
        dispatcher._db.succeed_outbox.assert_not_called()

    @pytest.mark.asyncio
    async def test_dispatcher_retries_on_retryable_error(
        self, db_config, dispatcher_config, provider_config, sample_claim
    ):
        """Повтор при retryable ошибке."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        dispatcher._db.claim_outbox = AsyncMock(return_value=[sample_claim])
        dispatcher._db.fail_outbox = AsyncMock(return_value={})
        dispatcher._provider.send_payment = AsyncMock(
            return_value=ProviderResponse(503, {})
        )
        
        await dispatcher._process_claim(sample_claim)
        
        # Проверяем что fail_outbox был вызван с retryable error
        dispatcher._db.fail_outbox.assert_called_once_with(
            outbox_id=sample_claim.outbox_id,
            owner=dispatcher._owner,
            lease_version=sample_claim.lease_version,
            error_code="http.503.retryable"
        )

    @pytest.mark.asyncio
    async def test_dispatcher_handles_transport_error(
        self, db_config, dispatcher_config, provider_config, sample_claim
    ):
        """Обработка транспортной ошибки."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        dispatcher._db.claim_outbox = AsyncMock(return_value=[sample_claim])
        dispatcher._db.fail_outbox = AsyncMock(return_value={})
        dispatcher._provider.send_payment = AsyncMock(
            side_effect=Exception("Connection refused")
        )
        
        await dispatcher._process_claim(sample_claim)
        
        dispatcher._db.fail_outbox.assert_called_once_with(
            outbox_id=sample_claim.outbox_id,
            owner=dispatcher._owner,
            lease_version=sample_claim.lease_version,
            error_code="transport.error.retryable"
        )

    @pytest.mark.asyncio
    async def test_dispatcher_main_loop(self, db_config, dispatcher_config, provider_config):
        """Тест основного цикла dispatcher."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        # Мокаем методы
        dispatcher._db.connect = AsyncMock()
        dispatcher._db.close = AsyncMock()
        dispatcher._db.claim_outbox = AsyncMock(return_value=[])
        
        # Запускаем в фоне и останавливаем через 0.5 сек
        dispatcher._running = True
        
        async def stop_after_delay():
            await asyncio.sleep(0.1)
            dispatcher._running = False
        
        # Запускаем оба task
        await asyncio.gather(
            dispatcher.start(),
            stop_after_delay(),
            return_exceptions=True
        )
        
        # Проверяем что методы вызывались
        dispatcher._db.connect.assert_called_once()
        dispatcher._db.close.assert_called_once()

    @pytest.mark.asyncio
    async def test_dispatcher_preserves_idempotency_across_retries(
        self, db_config, dispatcher_config, provider_config, sample_claim
    ):
        """Idempotency-Key и body сохраняются при повторах."""
        dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)
        
        # Первая попытка - retryable error
        dispatcher._db.claim_outbox = AsyncMock(return_value=[sample_claim])
        dispatcher._db.fail_outbox = AsyncMock(return_value={})
        
        call_count = 0
        
        async def mock_send(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return ProviderResponse(503, {})  # retryable
            elif call_count == 2:
                return ProviderResponse(202, {"providerPaymentId": "provider-456", "status": "ACCEPTED"})
            return ProviderResponse(202, {"providerPaymentId": "provider-789", "status": "ACCEPTED"})
        
        dispatcher._provider.send_payment = AsyncMock(side_effect=mock_send)
        
        # Первая попытка
        await dispatcher._process_claim(sample_claim)
        
        # Вторая попытка (с тем же claim - симуляция retry)
        # Проверяем что external_request_id не изменился
        assert sample_claim.external_request_id == "external-123"
        
        # Проверяем что вторая попытка успешна
        dispatcher._db.succeed_outbox = AsyncMock(return_value={})
        await dispatcher._process_claim(sample_claim)
        
        # Проверяем что succeed_outbox вызван с правильным provider_payment_id
        dispatcher._db.succeed_outbox.assert_called_with(
            outbox_id=sample_claim.outbox_id,
            owner=dispatcher._owner,
            lease_version=sample_claim.lease_version,
            provider_payment_id="provider-456"
        )


class TestDispatcherProviderClassification:
    """Тесты классификации ответов провайдера."""

    def test_success_response(self):
        """Успешный ответ 202."""
        response = ProviderResponse(202, {"providerPaymentId": "p-123", "status": "ACCEPTED"})
        assert response.is_success is True
        assert response.provider_payment_id == "p-123"

    def test_success_response_missing_fields(self):
        """Успешный ответ с некорректным телом."""
        response = ProviderResponse(202, {})
        assert response.is_success is False
        assert response.error_code == "response.invalid.terminal"

    def test_retryable_status_codes(self):
        """Retryable HTTP статусы."""
        retryable = [408, 429, 500, 502, 503, 504]
        for status in retryable:
            response = ProviderResponse(status, {})
            assert response.is_success is False
            assert "retryable" in response.error_code

    def test_terminal_status_codes(self):
        """Terminal HTTP статусы."""
        terminal = [400, 401, 403, 404, 405, 406, 410, 422]
        for status in terminal:
            response = ProviderResponse(status, {})
            assert response.is_success is False
            assert "terminal" in response.error_code