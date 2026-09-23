# python/outbox_dispatcher.py
import asyncio
import logging
from typing import Optional
from uuid import UUID

from .config import DispatcherConfig, ProviderConfig, DatabaseConfig
from .db import DatabaseClient
from .provider_client import ProviderClient
from .models import OutboxClaim

logger = logging.getLogger(__name__)


class OutboxDispatcher:
    """
    Python outbox-dispatcher.
    
    Роль: outbox_dispatcher
    Доступ: только EXECUTE на delivery.claim/succeed/fail_outbox
    Не имеет прямого DML доступа к таблицам.
    """
    
    def __init__(
        self,
        db_config: DatabaseConfig,
        dispatcher_config: DispatcherConfig,
        provider_config: ProviderConfig
    ):
        self._db = DatabaseClient(db_config)
        self._provider = ProviderClient(provider_config)
        self._owner = dispatcher_config.owner
        self._claim_limit = dispatcher_config.claim_limit
        self._running = False
    
    async def start(self) -> None:
        """Запускает цикл обработки Outbox."""
        await self._db.connect()
        self._running = True
        
        logger.info(f"OutboxDispatcher started (owner={self._owner})")
        
        while self._running:
            try:
                claims = await self._db.claim_outbox(self._owner, self._claim_limit)
                
                for claim in claims:
                    await self._process_claim(claim)
                
                if not claims:
                    await asyncio.sleep(0.5)
                    
            except Exception as e:
                logger.error(f"Error in dispatcher loop: {e}", exc_info=True)
                await asyncio.sleep(1)
    
    async def stop(self) -> None:
        """Останавливает dispatcher."""
        self._running = False
        await self._db.close()
        logger.info("OutboxDispatcher stopped")
    
    async def _process_claim(self, claim: OutboxClaim) -> None:
        """
        Обрабатывает один Outbox claim.
        Один claim = одна HTTP попытка к провайдеру.
        """
        logger.info(f"Processing claim: {claim.outbox_id}, request={claim.external_request_id}")
        
        try:
            # Отправка запроса к провайдеру
            response = await self._provider.send_payment(
                operation_id=claim.external_request_id,
                amount=claim.amount,
                currency=claim.currency,
                correlation_id=claim.correlation_id
            )
            
            if response.is_success:
                # Успешное принятие
                await self._db.succeed_outbox(
                    outbox_id=claim.outbox_id,
                    owner=self._owner,
                    lease_version=claim.lease_version,
                    provider_payment_id=response.provider_payment_id
                )
                logger.info(f"Outbox succeeded: {claim.outbox_id}")
            else:
                # Ошибка (retryable или terminal)
                await self._db.fail_outbox(
                    outbox_id=claim.outbox_id,
                    owner=self._owner,
                    lease_version=claim.lease_version,
                    error_code=response.error_code
                )
                logger.warning(f"Outbox failed: {claim.outbox_id}, error={response.error_code}")
                
        except Exception as e:
            # Transport error или timeout
            logger.error(f"Transport error for {claim.outbox_id}: {e}")
            await self._db.fail_outbox(
                outbox_id=claim.outbox_id,
                owner=self._owner,
                lease_version=claim.lease_version,
                error_code="transport.error.retryable"
            )