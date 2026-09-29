# python/outbox_dispatcher.py
import asyncio
import logging
import time
from typing import Optional
from uuid import UUID

from .config import DatabaseConfig, DispatcherConfig, ProviderConfig, RuntimeProfile
from .db import DatabaseClient
from .provider_client import ProviderClient, ProviderResponse
from .observability import Failpoint, HealthServer, log_event

logger = logging.getLogger(__name__)


class OutboxDispatcher:
    """
    Python outbox-dispatcher.

    Роль: outbox_dispatcher
    Доступ: только EXECUTE на delivery.claim_outbox/succeed_outbox/fail_outbox.
    Не имеет прямого DML доступа к таблицам.

    Неделя 4: может запускаться в двух экземплярах одновременно
    (outbox-dispatcher / outbox-dispatcher-b в docker-compose.yml) — claim
    короткой транзакцией с owner+leaseVersion в PostgreSQL делает второй
    экземпляр безопасным по конструкции, не по конвенции (см.
    011_delivery_functions.sql: FOR UPDATE SKIP LOCKED + условное
    succeed/fail по owner+leaseVersion).
    """

    def __init__(
        self,
        db_config: DatabaseConfig,
        dispatcher_config: DispatcherConfig,
        provider_config: ProviderConfig,
        profile: Optional[RuntimeProfile] = None,
    ):
        # Порядок аргументов сохранён как в неделе 3 (db, dispatcher, provider) —
        # открытые тесты и внешний код не ломаются; profile необязателен.
        if profile is None:
            profile = RuntimeProfile(
                test_profile=False, failpoint=None,
                instance_id=dispatcher_config.owner, health_port=8080,
            )
        self._db = DatabaseClient(db_config, dispatcher_config.session_settings)
        self._provider = ProviderClient(provider_config)
        self._owner = dispatcher_config.owner
        self._poll_interval = dispatcher_config.poll_interval_seconds
        self._claim_limit = dispatcher_config.claim_limit
        self._running = False
        self._closed = False
        self._failpoint = Failpoint(profile.test_profile, profile.failpoint, profile.instance_id, logger)
        self._health = HealthServer(self._is_ready, profile.health_port, logger)

    async def _is_ready(self) -> bool:
        try:
            return await self._db.ping()
        except Exception:
            return False

    async def start(self) -> None:
        """Запускает цикл dispatch."""
        await self._db.connect()
        await self._health.start()
        self._running = True

        log_event(logger, logging.INFO, "dispatcher.started", owner=self._owner)

        try:
            while self._running:
                try:
                    claims = await self._db.claim_outbox(self._owner, self._claim_limit)

                    if claims:
                        # after_outbox_claim: claim уже закоммичен, HTTP к provider
                        # ещё не выполнялся. Точка достигается только когда работа
                        # реально захвачена — иначе dispatcher замирал бы на первом
                        # же пустом poll'е, до появления Outbox-строки.
                        await self._failpoint.hit("after_outbox_claim")
                        await asyncio.gather(*(self._process_claim(claim) for claim in claims))
                    else:
                        await asyncio.sleep(self._poll_interval)

                except Exception as e:
                    log_event(logger, logging.ERROR, "dispatcher.loop_error", error=str(type(e).__name__))
                    await asyncio.sleep(1)
        finally:
            await self._shutdown()

    async def _process_claim(self, claim) -> None:
        """Обрабатывает одну захваченную запись Outbox."""
        log_event(
            logger, logging.INFO, "outbox.claimed",
            outboxId=str(claim.outbox_id), owner=self._owner,
            leaseVersion=claim.lease_version, externalRequestId=claim.external_request_id,
            correlationId=str(claim.correlation_id),
        )

        started = time.monotonic()
        try:
            response = await self._provider.send_payment(
                operation_id=claim.external_request_id,
                amount=claim.amount,
                currency=claim.currency,
                correlation_id=claim.correlation_id
            )
        except Exception:
            # Любой непредвиденный сбой транспорта (не только timeout/ClientError,
            # которые ProviderClient уже превращает в status=0) — это retryable
            # попытка, а не потерянная строка: без fail_outbox она осталась бы
            # LEASED до истечения lease.
            response = ProviderResponse(0, {})
        duration_ms = int((time.monotonic() - started) * 1000)

        await self._failpoint.hit("after_provider_response")

        if response.is_success:
            log_event(
                logger, logging.INFO, "provider.response.received",
                outboxId=str(claim.outbox_id), httpStatus=response.status, durationMs=duration_ms,
            )
            await self._db.succeed_outbox(
                outbox_id=claim.outbox_id,
                owner=self._owner,
                lease_version=claim.lease_version,
                provider_payment_id=response.provider_payment_id
            )
            log_event(logger, logging.INFO, "outbox.delivered", outboxId=str(claim.outbox_id))
        else:
            error_code = response.error_code
            level = logging.WARNING if error_code.endswith(".retryable") else logging.ERROR
            log_event(
                logger, level, "provider.request.failed",
                outboxId=str(claim.outbox_id), httpStatus=response.status,
                errorCode=error_code, durationMs=duration_ms,
            )
            result = await self._db.fail_outbox(
                outbox_id=claim.outbox_id,
                owner=self._owner,
                lease_version=claim.lease_version,
                error_code=error_code
            )
            if isinstance(result, dict) and result.get("status") == "error":
                # delivery.lease_stale — второй dispatcher (или reclaim
                # после lease-expiry) уже забрал эту запись; наш ответ от
                # provider — просроченная попытка, отбрасываем её молча.
                log_event(logger, logging.WARNING, "delivery.lease_stale", outboxId=str(claim.outbox_id))
                return
            outbox_state = result.get("outboxState") if isinstance(result, dict) else None
            if outbox_state == "DEAD":
                log_event(logger, logging.ERROR, "outbox.dead", outboxId=str(claim.outbox_id), errorCode=error_code)
            else:
                log_event(
                    logger, logging.WARNING, "outbox.retry.scheduled",
                    outboxId=str(claim.outbox_id),
                    nextAttemptDelayMs=(result or {}).get("nextAttemptDelayMs"),
                )

    async def _shutdown(self) -> None:
        """Идемпотентное освобождение ресурсов (loop завершился сам или вызван stop())."""
        if self._closed:
            return
        self._closed = True
        await self._health.stop()
        await self._provider.close()
        await self._db.close()
        log_event(logger, logging.INFO, "dispatcher.stopped")

    async def stop(self) -> None:
        """Останавливает dispatcher."""
        self._running = False
        await self._shutdown()
