# python/db.py
import asyncpg
from typing import Optional, List, Any, Dict
import json
from uuid import UUID

from .config import DatabaseConfig
from .models import OutboxClaim


class DatabaseClient:
    """Асинхронный клиент для PostgreSQL с least-privilege доступом."""
    
    def __init__(self, config: DatabaseConfig):
        self._config = config
        self._pool: Optional[asyncpg.Pool] = None
    
    async def connect(self) -> None:
        """Создаёт пул соединений."""
        self._pool = await asyncpg.create_pool(
            self._config.dsn,
            min_size=1,
            max_size=5,
            command_timeout=10
        )
    
    async def close(self) -> None:
        """Закрывает пул."""
        if self._pool:
            await self._pool.close()
    
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