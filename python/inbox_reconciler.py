# python/inbox_reconciler.py
import asyncio
import logging

from .config import DatabaseConfig, ReconcilerConfig, RuntimeProfile
from .db import DatabaseClient
from .observability import Failpoint, HealthServer, log_event

logger = logging.getLogger(__name__)


class InboxReconciler:
    """
    Python inbox-reconciler.

    Роль: inbox_reconciler
    Доступ: только EXECUTE на delivery.reconcile_inbox(integer).
    Не имеет прямого DML доступа к таблицам.

    Неделя 4: может запускаться в двух экземплярах одновременно
    (inbox-reconciler / inbox-reconciler-b) — delivery.reconcile_inbox
    сам обязан быть написан так, чтобы конкурентный вызов двух
    инстансов был безопасен (FOR UPDATE SKIP LOCKED внутри), это не
    меняется этой правкой, только добавляются health/failpoint/логи.
    """

    def __init__(
        self,
        db_config: DatabaseConfig,
        reconciler_config: ReconcilerConfig,
        profile: RuntimeProfile,
    ):
        self._db = DatabaseClient(db_config)
        self._poll_interval = reconciler_config.poll_interval_seconds
        self._batch_limit = reconciler_config.batch_limit
        self._running = False
        self._failpoint = Failpoint(profile.test_profile, profile.failpoint, profile.instance_id, logger)
        self._health = HealthServer(self._is_ready, profile.health_port, logger)

    async def _is_ready(self) -> bool:
        try:
            return await self._db.ping()
        except Exception:
            return False

    async def start(self) -> None:
        """Запускает цикл reconciliation."""
        await self._db.connect()
        await self._health.start()
        self._running = True

        log_event(logger, logging.INFO, "reconciler.started")

        while self._running:
            try:
                count = await self._db.reconcile_inbox(self._batch_limit)

                # FIX: failpoint after_inbox_saved принадлежит компоненту api
                # (docs/07-autocheck-outline.md), а не reconciler'у — reconciler
                # здесь только применяет уже сохранённый Inbox.
                if count > 0:
                    log_event(logger, logging.INFO, "inbox.reconciled", appliedCount=count)

                await asyncio.sleep(self._poll_interval)

            except Exception as e:
                log_event(logger, logging.ERROR, "reconciler.loop_error", error=str(type(e).__name__))
                await asyncio.sleep(1)

    async def stop(self) -> None:
        """Останавливает reconciler."""
        self._running = False
        await self._health.stop()
        await self._db.close()
        log_event(logger, logging.INFO, "reconciler.stopped")
