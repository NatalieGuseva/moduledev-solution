# python/db.py
import asyncpg
from typing import Optional, List, Any, Dict
import json
from uuid import UUID

from .config import DatabaseConfig
from .models import OutboxClaim


class DatabaseClient:
    """Асинхронный клиент для PostgreSQL с least-privilege доступом."""
    
    def __init__(self, config: DatabaseConfig, server_settings: Optional[Dict[str, str]] = None):
        self._config = config
        # Параметры сессии (GUC), например course.outbox_lease_ms — их читают
        # SQL-функции через current_setting(); сигнатуры функций не меняются.
        self._server_settings = server_settings or {}
        self._pool: Optional[asyncpg.Pool] = None
    
    async def connect(self) -> None:
        """Создаёт пул соединений."""
        self._pool = await asyncpg.create_pool(
            self._config.dsn,
            min_size=1,
            max_size=5,
            command_timeout=10,
            server_settings=self._server_settings or None
        )
    
    async def close(self) -> None:
        """Закрывает пул."""
        if self._pool:
            await self._pool.close()

    async def ping(self) -> bool:
        """Лёгкая проверка соединения для /health/ready — SELECT 1 не
        требует никаких табличных grant'ов (в отличие от прямого чтения
        delivery.outbox), поэтому безопасен для outbox_dispatcher/
        inbox_reconciler ролей с их fixed-function-only доступом."""
        if self._pool is None:
            return False
        async with self._pool.acquire() as conn:
            value = await conn.fetchval("SELECT 1")
            return value == 1
    
    async def claim_outbox(self, owner: str, limit: int = 10) -> List[OutboxClaim]:
        """
        Вызывает delivery.claim_outbox.
        Используется только outbox-dispatcher.
        """
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT * FROM delivery.claim_outbox($1, $2)",
                owner, limit
            )
            return [
                OutboxClaim(
                    outbox_id=row["outbox_id"],
                    lease_version=row["lease_version"],
                    external_request_id=row["external_request_id"],
                    correlation_id=row["correlation_id"],
                    amount=row["amount"],
                    currency=row["currency"]
                )
                for row in rows
            ]
    
    async def succeed_outbox(
        self,
        outbox_id: UUID,
        owner: str,
        lease_version: int,
        provider_payment_id: str
    ) -> Dict[str, Any]:
        """
        Вызывает delivery.succeed_outbox.
        Возвращает JSONB результат.
        """
        async with self._pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT delivery.succeed_outbox($1, $2, $3, $4)",
                outbox_id, owner, lease_version, provider_payment_id
            )
            return json.loads(result) if result else {}
    
    async def fail_outbox(
        self,
        outbox_id: UUID,
        owner: str,
        lease_version: int,
        error_code: str
    ) -> Dict[str, Any]:
        """
        Вызывает delivery.fail_outbox.
        Возвращает JSONB результат.
        """
        async with self._pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT delivery.fail_outbox($1, $2, $3, $4)",
                outbox_id, owner, lease_version, error_code
            )
            return json.loads(result) if result else {}
    
    async def reconcile_inbox(self, limit: int = 100) -> int:
        """
        Вызывает delivery.reconcile_inbox.
        Используется только inbox-reconciler.
        Возвращает число применённых сообщений.
        """
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT delivery.reconcile_inbox($1)",
                limit
            )