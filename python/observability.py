# python/observability.py
"""
Общая инфраструктура наблюдаемости для python-сервисов (outbox-dispatcher,
inbox-reconciler, receipt-adapter): структурные JSON-логи, health-эндпоинты,
/metrics (OpenMetrics) и failpoints недели 4.

Один модуль, а не по копии в каждом сервисе — иначе формат события/лога
неизбежно разойдётся между dispatcher'ом и reconciler'ом уже на первом
рефакторинге одного из них.
"""
import asyncio
import json
import logging
import sys
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Optional

from aiohttp import web

_SERVICE_NAME = "service"

# observability-contracts.md: media type для /metrics.
OPENMETRICS_CONTENT_TYPE = "application/openmetrics-text; version=1.0.0; charset=utf-8"


def _openmetrics_document(service_name: str) -> str:
    """Минимальный валидный OpenMetrics-документ.

    Шесть обязательных серий (workflow_jobs_ready, workflow_job_oldest_age_seconds,
    workflow_processes_waiting, outbox_pending, outbox_oldest_age_seconds,
    workflow_failures) публикует только api. Остальным проверяемым процессам
    контракт требует лишь корректный документ с завершающим # EOF и
    правильным Content-Type.
    """
    return (
        "# HELP python_service_up Python integration service is running.\n"
        "# TYPE python_service_up gauge\n"
        f'python_service_up{{service="{service_name}"}} 1\n'
        "# EOF\n"
    )


class JsonFormatter(logging.Formatter):
    """Один лог = одна JSON-строка в stdout.

    Если запись сделана через log_event() (см. ниже), record.msg — уже
    готовый dict полей события; иначе (сторонние библиотеки, редкие
    logger.info("строка")) — оборачиваем как {"message": "..."}. Так
    сторонние библиотеки (aiohttp access log и т.п.) не роняют формат.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any]
        if isinstance(record.msg, dict):
            payload = dict(record.msg)
            if record.args:
                pass
        else:
            payload = {"message": record.getMessage()}

        payload.setdefault("level", record.levelname)
        payload.setdefault("service", _SERVICE_NAME)
        payload.setdefault("timestamp", datetime.now(timezone.utc).isoformat())

        if record.exc_info:
            payload["traceback"] = self.formatException(record.exc_info)

        return json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str)


def configure_json_logging(service_name: str, level: int = logging.INFO) -> None:
    """Вызывается ровно один раз на процесс, в самом начале run_*()."""
    global _SERVICE_NAME
    _SERVICE_NAME = service_name

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)


def log_event(logger: logging.Logger, level: int, event: str, **fields: Any) -> None:
    """Пишет одну структурную строку: {"event": ..., level, service, timestamp, **fields}.

    ВАЖНО (контракт "Чего в логах быть не должно"): вызывающая сторона
    обязана сама не передавать сюда JWT/HMAC-signature/пароли/полный
    payload/receipt body/message из callback/reason ручного решения.
    """
    logger.log(level, {"event": event, **fields})


class Failpoint:
    """Одна контрольная точка сбоя недели 4.

    Активна только при test_profile=True И instance_target == COURSE_FAILPOINT.
    """

    def __init__(self, test_profile: bool, target: Optional[str], instance_id: str, logger: logging.Logger):
        self._enabled = bool(test_profile and target)
        self._target = target
        self._instance_id = instance_id
        self._logger = logger

    async def hit(self, name: str) -> None:
        if not self._enabled or name != self._target:
            return
        log_event(self._logger, logging.INFO, "failpoint.reached", name=name, instanceId=self._instance_id)
        await asyncio.Event().wait()


ReadyCheck = Callable[[], Awaitable[bool]]


class HealthServer:
    """Отдельный aiohttp-сервер: /health/live + /health/ready + /metrics.

    Используется outbox-dispatcher'ом и inbox-reconciler'ом — у них иначе
    нет ни одного HTTP listener'а вообще (receipt-adapter добавляет те же
    три route в свой уже существующий web.Application, см. receipt_adapter.py,
    а не эту обёртку, потому что порт там и так занят под callback).
    """

    def __init__(self, ready_check: ReadyCheck, port: int, logger: logging.Logger):
        self._ready_check = ready_check
        self._port = port
        self._logger = logger
        self._runner: Optional[web.AppRunner] = None

    def _build_app(self) -> web.Application:
        app = web.Application()
        app.router.add_get("/health/live", self._live)
        app.router.add_get("/health/ready", self._ready)
        app.router.add_get("/metrics", self._metrics)
        return app

    async def _live(self, request: web.Request) -> web.Response:
        return web.json_response({"status": "live"})

    async def _ready(self, request: web.Request) -> web.Response:
        try:
            ok = await self._ready_check()
        except Exception:
            ok = False
        if ok:
            return web.json_response({"status": "ready"})
        return web.json_response(
            {"status": "not_ready", "code": "dependency.unavailable"}, status=503
        )

    async def _metrics(self, request: web.Request) -> web.Response:
        return web.Response(
            text=_openmetrics_document(_SERVICE_NAME),
            headers={"Content-Type": OPENMETRICS_CONTENT_TYPE},
        )

    async def start(self) -> None:
        app = self._build_app()
        self._runner = web.AppRunner(app, access_log=None)
        await self._runner.setup()
        site = web.TCPSite(self._runner, "0.0.0.0", self._port)
        await site.start()
        self._logger.info({"event": "health_server.started", "port": self._port})

    async def stop(self) -> None:
        if self._runner:
            await self._runner.cleanup()


def add_health_routes(app: web.Application, ready_check: ReadyCheck) -> None:
    """Для сервисов, у которых УЖЕ есть свой web.Application (receipt-adapter) —
    добавляет /health/live, /health/ready и /metrics в тот же порт вместо
    отдельного HealthServer."""

    async def live(request: web.Request) -> web.Response:
        return web.json_response({"status": "live"})

    async def ready(request: web.Request) -> web.Response:
        try:
            ok = await ready_check()
        except Exception:
            ok = False
        if ok:
            return web.json_response({"status": "ready"})
        return web.json_response(
            {"status": "not_ready", "code": "dependency.unavailable"}, status=503
        )

    async def metrics(request: web.Request) -> web.Response:
        return web.Response(
            text=_openmetrics_document(_SERVICE_NAME),
            headers={"Content-Type": OPENMETRICS_CONTENT_TYPE},
        )

    app.router.add_get("/health/live", live)
    app.router.add_get("/health/ready", ready)
    app.router.add_get("/metrics", metrics)