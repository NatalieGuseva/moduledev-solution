# python/receipt_adapter.py
import hashlib
import json
import logging
import os
from typing import Optional
from aiohttp import web, ClientSession, ClientTimeout, ClientResponse
from aiohttp.web_response import Response

from .config import AdapterConfig
from .models import ProviderCallback, ReceiptV1
from .hmac_utils import compute_hmac_signature

logger = logging.getLogger(__name__)


class ReceiptAdapter:
    """
    Python receipt-adapter.
    
    Преобразует legacy callback от provider в signed receipt v1.
    Не имеет PostgreSQL credentials.
    """
    
    def __init__(self, config: AdapterConfig):
        self._config = config
        self._app = web.Application()
        self._app.router.add_post(
            f"/callbacks/provider-v02/{{capability}}",
            self._handle_callback
        )
        self._runner: Optional[web.AppRunner] = None
    
    def app(self) -> web.Application:
        return self._app
    
    async def _handle_callback(self, request: web.Request) -> web.Response:
        """Обрабатывает legacy callback от provider."""
        capability = request.match_info.get("capability")
        
        # Проверка capability
        if capability != self._config.capability:
            logger.warning(f"Invalid capability: {capability}")
            return web.Response(status=404)
        
        # Чтение тела
        try:
            body_size = request.content_length or 0
            if body_size > self._config.max_body_size:
                return web.Response(status=400, text="")
            
            raw_body = await request.text()
        except:
            return web.Response(status=400, text="")
        
        # Парсинг и валидация
        try:
            data = json.loads(raw_body)
            callback = ProviderCallback.from_dict(data)
        except (json.JSONDecodeError, ValueError) as e:
            logger.warning(f"Invalid callback: {e}")
            return web.Response(status=400, text="")
        
        # Преобразование в receipt v1
        receipt = ReceiptV1.from_legacy(callback)
        body_bytes = receipt.to_compact_json_bytes()
        
        # Вычисление HMAC
        signature = compute_hmac_signature(
            self._config.hmac_secret,
            body_bytes
        )
        
        # Отправка в gateway
        try:
            response = await self._send_to_gateway(receipt, body_bytes, signature)
            
            # Проксируем ответ от API
            status = response.status
            response_body = await response.text()
            return web.Response(
                status=status,
                body=response_body,
                content_type=response.content_type
            )
            
        except Exception as e:
            logger.error(f"Gateway error: {e}")
            return web.json_response(
                {"status": "error", "code": "dependency.unavailable"},
                status=503
            )
    
    async def _send_to_gateway(
        self,
        receipt: ReceiptV1,
        body_bytes: bytes,
        signature: str
    ) -> ClientResponse:
        """Отправляет receipt в generic C# API."""
        url = self._config.receipt_api_url
        headers = {
            "Authorization": f"Bearer {self._config.token}",
            "Content-Type": "application/json",
            "Idempotency-Key": receipt.message_id,
            "X-Action-Version": "1",
            "X-Provider-Signature": signature
        }
        # DEBUG: печатаем точные байты, которые подписываем и отправляем
        logger.info(
            "OUTGOING RECEIPT url=%s idempotency_key=%s signature=%s body_repr=%r",
            url, receipt.message_id, signature, body_bytes
        )
        
        timeout = ClientTimeout(total=10.0)
        async with ClientSession(timeout=timeout) as session:
            return await session.post(
                url,
                data=body_bytes,  # Важно: передаём exact bytes, а не json
                headers=headers
            )
    
    async def start(
        self,
        host: str = "0.0.0.0",
        # FIX: было port: int = 8082 (хардкод) — provider-simulator
        # в docker-compose.yml стучится на receipt-adapter:8080
        # (CALLBACK_URL=http://receipt-adapter:8080/callbacks/...),
        # поэтому adapter ОБЯЗАН слушать 8080, иначе callback
        # получает "connection refused", Inbox не наполняется, и
        # чекер виснет на run-summary → "timed out waiting for
        # candidate evidence". Дефолт 8080 согласован с CALLBACK_URL
        # и с остальными сервисами (gateway, api); порт можно
        # переопределить env-переменной RECEIPT_ADAPTER_PORT.
        port: Optional[int] = None,
    ) -> None:
        """Запускает HTTP сервер."""
        if port is None:
            port = int(os.environ.get("RECEIPT_ADAPTER_PORT", "8080"))
        self._runner = web.AppRunner(self._app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, host, port)
        await site.start()
        logger.info(f"ReceiptAdapter started on {host}:{port}")
    
    async def stop(self) -> None:
        """Останавливает сервер."""
        if self._runner:
            await self._runner.cleanup()