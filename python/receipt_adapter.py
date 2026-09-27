# python/receipt_adapter.py
import logging
import os
import time
from typing import Optional, Tuple
import aiohttp
from aiohttp import web, ClientSession, ClientTimeout
from aiohttp.web_response import Response

from .config import AdapterConfig
from .models import ProviderCallback, ReceiptV1
from .hmac_utils import compute_hmac_signature
from .observability import add_health_routes, log_event

logger = logging.getLogger(__name__)


class ReceiptAdapter:
    """
    Python receipt-adapter.

    Преобразует legacy callback от provider в signed receipt v1.
    Не имеет PostgreSQL credentials.

    Слушает внутренний порт 8082 (configuration.md, таблица
    "Служебные порты": receipt-adapter | 8082). CALLBACK_URL в
    docker-compose.yml указывает provider'у ровно на этот порт.
    """

    def __init__(self, config: AdapterConfig):
        self._config = config
        self._app = web.Application()
        self._app.router.add_post(
            f"/callbacks/provider-v02/{{capability}}",
            self._handle_callback
        )
        add_health_routes(self._app, self._check_gateway_ready)
        self._runner: Optional[web.AppRunner] = None
        self._gateway_check_session: Optional[ClientSession] = None

    def app(self) -> web.Application:
        return self._app

    async def _check_gateway_ready(self) -> bool:
        try:
            if self._gateway_check_session is None or self._gateway_check_session.closed:
                self._gateway_check_session = ClientSession(timeout=ClientTimeout(total=2.0))
            async with self._gateway_check_session.get(
                f"{self._config.gateway_url}/health/live"
            ) as resp:
                return resp.status == 200
        except Exception:
            return False

    async def _read_bounded_body(self, request: web.Request) -> Optional[bytes]:
        """Читает тело потоково, независимо от Content-Length (chunked или
        нет — не важно), и обрывает как только суммарный размер превышает
        max_body_size.
        """
        limit = self._config.max_body_size
        total = 0
        chunks: list[bytes] = []
        try:
            async for chunk in request.content.iter_chunked(8192):
                total += len(chunk)
                if total > limit:
                    return None
                chunks.append(chunk)
        except (aiohttp.ClientError, ConnectionError):
            return None
        return b"".join(chunks)

    async def _handle_callback(self, request: web.Request) -> web.Response:
        """Обрабатывает legacy callback от provider."""
        capability = request.match_info.get("capability")

        if capability != self._config.capability:
            log_event(logger, logging.WARNING, "callback.invalid_capability")
            return web.Response(status=404)

        raw_bytes = await self._read_bounded_body(request)
        if raw_bytes is None:
            log_event(logger, logging.WARNING, "callback.body_too_large_or_unreadable")
            return web.Response(status=400, text="")

        try:
            raw_body = raw_bytes.decode("utf-8")
        except UnicodeDecodeError:
            log_event(logger, logging.WARNING, "callback.invalid_encoding")
            return web.Response(status=400, text="")

        try:
            import json
            data = json.loads(raw_body)
            callback = ProviderCallback.from_dict(data)
        except (ValueError,) as e:
            log_event(logger, logging.WARNING, "callback.invalid")
            return web.Response(status=400, text="")

        try:
            receipt = ReceiptV1.from_legacy(callback)
        except ValueError:
            log_event(logger, logging.WARNING, "callback.invalid_result", operationId=callback.operation_id)
            return web.Response(status=400, text="")

        body_bytes = receipt.to_compact_json_bytes()
        signature = compute_hmac_signature(self._config.hmac_secret, body_bytes)

        try:
            started = time.monotonic()
            status, response_body = await self._send_to_gateway(
                receipt, body_bytes, signature
            )
            duration_ms = int((time.monotonic() - started) * 1000)

            log_event(
                logger, logging.INFO, "receipt.sent",
                externalRequestId=receipt.external_request_id,
                messageId=receipt.message_id,
                httpStatus=status,
                durationMs=duration_ms,
            )

            # FIX (неделя 4): НЕ пробрасываем content_type от gateway через
            # web.Response(content_type=...) — aiohttp запрещает charset
            # в этом параметре и падает с ValueError на значении
            # "application/json; charset=utf-8", которое gateway возвращает
            # на 409 conflict (проверка adapter-conflicting-callback).
            # Передаём Content-Type через headers — там charset допустим
            # и просто выставляется как есть.
            return web.Response(
                status=status,
                body=response_body,
                headers={"Content-Type": "application/json"},
            )

        except Exception as e:
            # FIX (неделя 4): раньше здесь был "except Exception:" без
            # диагностики — в логах виднелось только "gateway.unavailable",
            # без типа и текста ошибки, что делало диагностику невозможной.
            # Теперь логируем тип исключения и его repr (только их, без
            # тела запроса/HMAC/токенов).
            log_event(
                logger, logging.ERROR, "gateway.unavailable",
                externalRequestId=receipt.external_request_id,
                messageId=receipt.message_id,
                errorType=type(e).__name__,
                error=repr(e),
            )
            return web.json_response(
                {"status": "error", "code": "dependency.unavailable"},
                status=503,
            )

    async def _send_to_gateway(
        self,
        receipt: ReceiptV1,
        body_bytes: bytes,
        signature: str,
    ) -> Tuple[int, bytes]:
        """Отправляет receipt в generic C# API.

        FIX (неделя 4): раньше возвращался ClientResponse как есть, но
        ClientSession закрывалась в `async with` при выходе из функции —
        к моменту, когда вызывающий код пытался прочитать response.text(),
        соединение было уже закрыто, и aiohttp бросал ClientConnectionError.
        На первом/втором запросе это иногда проходило (TCP-буфер), но
        на третьем (conflicting callback, 409 от gateway) гарантированно
        ломалось — checker фиксировал adapter-conflicting-callback failed.

        Теперь читаем status/body ЦЕЛИКОМ внутри `async with` — до того,
        как сессия закроется — и возвращаем кортеж примитивов. Content-Type
        от gateway НЕ пробрасываем: на 409 gateway отдаёт
        "application/json; charset=utf-8", а web.Response(content_type=...)
        запрещает charset и падает с ValueError.
        """
        url = self._config.receipt_api_url
        headers = {
            "Authorization": f"Bearer {self._config.token}",
            "Content-Type": "application/json",
            "Idempotency-Key": receipt.message_id,
            "X-Action-Version": "1",
            "X-Provider-Signature": signature,
        }
        # В лог не попадают url, Idempotency-Key, HMAC signature и тело
        # receipt — контракт логирования это прямо запрещает.
        timeout = ClientTimeout(total=10.0)
        async with ClientSession(timeout=timeout) as session:
            async with session.post(url, data=body_bytes, headers=headers) as resp:
                body = await resp.read()
                return resp.status, body

    async def start(
        self,
        host: str = "0.0.0.0",
        port: Optional[int] = None,
    ) -> None:
        """Запускает HTTP сервер.

        Порт берётся из RECEIPT_ADAPTER_PORT с дефолтом 8082 —
        configuration.md фиксирует именно этот внутренний порт
        для receipt-adapter. CALLBACK_URL в docker-compose.yml
        указывает provider'у на этот же порт.
        """
        if port is None:
            port = int(os.environ.get("RECEIPT_ADAPTER_PORT", "8082"))
        self._runner = web.AppRunner(self._app, access_log=None)
        await self._runner.setup()
        site = web.TCPSite(self._runner, host, port)
        await site.start()
        log_event(logger, logging.INFO, "adapter.started", port=port)

    async def stop(self) -> None:
        """Останавливает сервер."""
        if self._gateway_check_session and not self._gateway_check_session.closed:
            await self._gateway_check_session.close()
        if self._runner:
            await self._runner.cleanup()