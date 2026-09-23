# python/provider_client.py
import asyncio
import logging
from typing import Optional
from uuid import UUID
import aiohttp

from .config import ProviderConfig
from .models import ProviderPaymentRequest

logger = logging.getLogger(__name__)


class ProviderResponse:
    """Ответ от провайдера."""
    
    def __init__(self, status: int, body: dict):
        self.status = status
        self.body = body
    
    @property
    def is_success(self) -> bool:
        """Проверяет HTTP 202 с корректным телом."""
        return (
            self.status == 202 and
            isinstance(self.body, dict) and
            "providerPaymentId" in self.body and
            self.body.get("status") == "ACCEPTED"
        )
    
    @property
    def provider_payment_id(self) -> str:
        return self.body.get("providerPaymentId", "")
    
    @property
    def error_code(self) -> str:
        """Код ошибки для fail_outbox согласно классификации."""
        if self.status == 408:
            return "http.408.retryable"
        elif self.status == 429:
            return "http.429.retryable"
        elif 500 <= self.status < 600:
            return f"http.{self.status}.retryable"
        elif 400 <= self.status < 500:
            return f"http.{self.status}.terminal"
        else:
            # Некорректный ответ
            return "response.invalid.terminal"


class ProviderClient:
    """HTTP клиент для provider-simulator v0.2.0."""
    
    def __init__(self, config: ProviderConfig):
        self._url = config.url
        self._timeout = config.timeout_seconds
        self._session: Optional[aiohttp.ClientSession] = None
    
    async def _ensure_session(self) -> None:
        if self._session is None or self._session.closed:
            timeout = aiohttp.ClientTimeout(total=self._timeout)
            self._session = aiohttp.ClientSession(timeout=timeout)
    
    async def send_payment(
        self,
        operation_id: str,
        amount: str,
        currency: str,
        correlation_id: UUID
    ) -> ProviderResponse:
        """
        Отправляет POST /payments провайдеру.
        
        Idempotency-Key = externalRequestId
        X-Correlation-ID = correlationId
        """
        await self._ensure_session()
        
        url = f"{self._url}/payments"
        body = ProviderPaymentRequest(
            operation_id=operation_id,
            amount=amount,
            currency=currency
        ).to_json()
        
        headers = {
            "Content-Type": "application/json",
            "Idempotency-Key": operation_id,
            "X-Correlation-ID": str(correlation_id)
        }
        
        try:
            async with self._session.post(url, json=body, headers=headers) as response:
                status = response.status
                try:
                    data = await response.json()
                except:
                    data = {}
                
                logger.info(f"Provider response: {status} for {operation_id}")
                return ProviderResponse(status, data)
                
        except asyncio.TimeoutError:
            logger.warning(f"Provider timeout for {operation_id}")
            # Возвращаем response для transport.error.retryable
            return ProviderResponse(0, {})
        except aiohttp.ClientError as e:
            logger.error(f"Provider connection error for {operation_id}: {e}")
            return ProviderResponse(0, {})
        finally:
            await self.close()
    
    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()