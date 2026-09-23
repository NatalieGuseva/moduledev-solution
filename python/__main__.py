# python/__main__.py
import logging
import sys
import asyncio

from .config import DatabaseConfig, DispatcherConfig, ProviderConfig, AdapterConfig
from .outbox_dispatcher import OutboxDispatcher
from .receipt_adapter import ReceiptAdapter
from .inbox_reconciler import InboxReconciler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def run_dispatcher() -> None:
    """Entrypoint для outbox-dispatcher."""
    logger.info("Starting outbox-dispatcher")

    db_config = DatabaseConfig.from_env("COURSE_OUTBOX")
    dispatcher_config = DispatcherConfig.from_env()
    provider_config = ProviderConfig.from_env()

    dispatcher = OutboxDispatcher(db_config, dispatcher_config, provider_config)

    try:
        asyncio.run(dispatcher.start())
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        asyncio.run(dispatcher.stop())


def run_adapter() -> None:
    """
    Entrypoint для receipt-adapter.

    adapter.start() запускает aiohttp web.AppRunner и сразу возвращает
    управление, поэтому одного asyncio.run(adapter.start()) недостаточно —
    процесс завершится, и контейнер уйдёт в Restarting.

    Правильный приём: создать event loop, запустить корутину через
    run_until_complete(), и затем держать loop живым через run_forever().
    В Python 3.12 asyncio.get_event_loop() без активного loop падает с
    RuntimeError — поэтому используем asyncio.new_event_loop() явно.

    Порт adapter'а НЕ передаётся здесь аргументом: ReceiptAdapter.start()
    сам читает RECEIPT_ADAPTER_PORT (дефолт 8080), чтобы совпасть с
    CALLBACK_URL у provider-simulator'а (http://receipt-adapter:8080/...).
    """
    logger.info("Starting receipt-adapter")

    adapter_config = AdapterConfig.from_env()
    adapter = ReceiptAdapter(adapter_config)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    try:
        # Без аргумента port — ReceiptAdapter.start() возьмёт
        # RECEIPT_ADAPTER_PORT (дефолт 8080), согласованный с CALLBACK_URL.
        loop.run_until_complete(adapter.start())
        loop.run_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        loop.run_until_complete(adapter.stop())
    finally:
        loop.close()


def run_reconciler() -> None:
    """Entrypoint для inbox-reconciler."""
    logger.info("Starting inbox-reconciler")

    db_config = DatabaseConfig.from_env("COURSE_INBOX")
    reconciler = InboxReconciler(db_config)

    try:
        asyncio.run(reconciler.start())
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        asyncio.run(reconciler.stop())


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python -m python <dispatcher|adapter|reconciler>")
        sys.exit(1)

    command = sys.argv[1]

    if command == "dispatcher":
        run_dispatcher()
    elif command == "adapter":
        run_adapter()
    elif command == "reconciler":
        run_reconciler()
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)