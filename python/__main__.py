# python/__main__.py
import asyncio
import logging
import signal
import sys

from .config import AdapterConfig, DatabaseConfig, DispatcherConfig, ProviderConfig, ReconcilerConfig, RuntimeProfile
from .outbox_dispatcher import OutboxDispatcher
from .inbox_reconciler import InboxReconciler
from .receipt_adapter import ReceiptAdapter
from .observability import configure_json_logging, log_event

logger = logging.getLogger(__name__)


async def _run_with_graceful_shutdown(component, start_coro) -> None:
    """Общий SIGTERM-обработчик для dispatcher/reconciler — соединения из
    пула берутся на каждую итерацию, поэтому просто просим цикл
    остановиться и дожидаемся текущей итерации."""
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _on_signal() -> None:
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _on_signal)

    run_task = asyncio.create_task(start_coro)
    stop_task = asyncio.create_task(stop_event.wait())

    done, pending = await asyncio.wait({run_task, stop_task}, return_when=asyncio.FIRST_COMPLETED)

    await component.stop()

    if run_task in pending:
        run_task.cancel()
        try:
            await run_task
        except asyncio.CancelledError:
            pass

    if run_task in done and run_task.exception():
        raise run_task.exception()


async def run_dispatcher() -> None:
    profile = RuntimeProfile.from_env(default_instance_id="outbox-dispatcher", default_health_port=8090)
    db_config = DatabaseConfig.from_env("COURSE_OUTBOX")
    provider_config = ProviderConfig.from_env(test_profile=profile.test_profile)
    dispatcher_config = DispatcherConfig.from_env(test_profile=profile.test_profile)

    dispatcher = OutboxDispatcher(db_config, provider_config, dispatcher_config, profile)
    await _run_with_graceful_shutdown(dispatcher, dispatcher.start())


async def run_reconciler() -> None:
    profile = RuntimeProfile.from_env(default_instance_id="inbox-reconciler", default_health_port=8091)
    db_config = DatabaseConfig.from_env("COURSE_INBOX")
    reconciler_config = ReconcilerConfig.from_env(test_profile=profile.test_profile)

    reconciler = InboxReconciler(db_config, reconciler_config, profile)
    await _run_with_graceful_shutdown(reconciler, reconciler.start())


async def run_adapter() -> None:
    adapter_config = AdapterConfig.from_env()
    adapter = ReceiptAdapter(adapter_config)

    await adapter.start()

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    await adapter.stop()


def main() -> None:
    component = sys.argv[1] if len(sys.argv) > 1 else "dispatcher"

    # service_name в JSON-логах различает outbox-dispatcher / -b и
    # inbox-reconciler / -b (см. пример лога dispatcher'а в задании:
    # "service": "outbox-dispatcher-b"). COURSE_INSTANCE_ID
    # (docker-compose.yml) или OUTBOX_OWNER — то, что реально задаёт
    # владельца lease в PostgreSQL, поэтому имя сервиса в логах и
    # значение owner в БД совпадают.
    import os
    service_name = (
        os.environ.get("COURSE_INSTANCE_ID")
        or os.environ.get("OUTBOX_OWNER")
        or component
    )
    configure_json_logging(service_name=service_name)

    if component == "dispatcher":
        asyncio.run(run_dispatcher())
    elif component == "reconciler":
        asyncio.run(run_reconciler())
    elif component == "adapter":
        asyncio.run(run_adapter())
    else:
        log_event(logger, logging.CRITICAL, "startup.unknown_component", component=component)
        sys.exit(1)


if __name__ == "__main__":
    main()
