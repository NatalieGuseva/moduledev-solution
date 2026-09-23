# python/inbox_reconciler.py
import asyncio
import logging
from typing import Optional

from .config import DatabaseConfig
from .db import DatabaseClient

logger = logging.getLogger(__name__)


class InboxReconciler:
    """
    Python inbox-reconciler.
    
    Роль: inbox_reconciler
    Доступ: только EXECUTE на delivery.reconcile_inbox(integer)
    Не имеет прямого DML доступа к таблицам.
    """
    
    def __init__(
        self,
        db_config: DatabaseConfig,
        poll_interval: float = 0.5,
        batch_limit: int = 100
    ):
        self._db = DatabaseClient(db_config)
        self._poll_interval = poll_interval
        self._batch_limit = batch_limit
        self._running = False
    
    async def start(self) -> None:
        """Запускает цикл reconciliation."""
        await self._db.connect()
        self._running = True
        
        logger.info("InboxReconciler started")
        
        while self._running:
            try:
                count = await self._db.reconcile_inbox(self._batch_limit)
                
                if count > 0:
                    logger.info(f"Applied {count} inbox messages")
                
                await asyncio.sleep(self._poll_interval)
                
            except Exception as e:
                logger.error(f"Error in reconciler loop: {e}", exc_info=True)
                await asyncio.sleep(1)
    
    async def stop(self) -> None:
        """Останавливает reconciler."""
        self._running = False
        await self._db.close()
        logger.info("InboxReconciler stopped")