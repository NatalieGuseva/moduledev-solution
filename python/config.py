# python/config.py
from dataclasses import dataclass
from os import environ
from typing import Optional
import re


@dataclass(frozen=True)
class DatabaseConfig:
    """Конфигурация подключения к PostgreSQL.

    ВАЖНО: поля без значения по умолчанию (user, password) идут ПЕРВЫМИ —
    этого требует Python: в @dataclass нельзя объявлять поле без default
    после поля с default (TypeError: non-default argument follows default argument).
    """
    user: str
    password: str
    host: str = "postgres"
    port: int = 5432
    dbname: str = "course"

    @classmethod
    def from_env(cls, prefix: str = "COURSE") -> "DatabaseConfig":
        """Создаёт конфиг из переменных окружения."""
        user = environ.get(f"{prefix}_USER")
        password = environ.get(f"{prefix}_PASSWORD")

        if not user or not password:
            raise ValueError(f"{prefix}_USER and {prefix}_PASSWORD are required")

        return cls(
            user=user,
            password=password,
            host=environ.get("POSTGRES_HOST", "postgres"),
            port=int(environ.get("POSTGRES_PORT", 5432)),
            dbname=environ.get("POSTGRES_DB", "course"),
        )

    @property
    def dsn(self) -> str:
        """PostgreSQL DSN для asyncpg/psycopg."""
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.dbname}"


@dataclass(frozen=True)
class RuntimeProfile:
    """Неделя 4: test profile / failpoint / instance identity / health port —
    общие для dispatcher, reconciler и adapter, поэтому вынесены в один
    dataclass, а не продублированы в каждом *Config.
    """
    test_profile: bool
    failpoint: Optional[str]
    instance_id: str
    health_port: int

    @classmethod
    def from_env(cls, default_instance_id: str, default_health_port: int) -> "RuntimeProfile":
        test_profile = environ.get("COURSE_TEST_PROFILE") == "1"
        return cls(
            test_profile=test_profile,
            failpoint=environ.get("COURSE_FAILPOINT") or None,
            instance_id=environ.get("COURSE_INSTANCE_ID", default_instance_id),
            health_port=int(environ.get("COURSE_HEALTH_PORT", default_health_port)),
        )


@dataclass(frozen=True)
class ProviderConfig:
    """Конфигурация провайдера.

    Здесь всё корректно: url без default идёт первым, timeout_seconds
    со значением — после него.
    """
    url: str
    timeout_seconds: float = 5.0

    @classmethod
    def from_env(cls, test_profile: bool = False) -> "ProviderConfig":
        url = environ.get("PROVIDER_URL", "http://provider-simulator:8081")
        # Неделя 4, test profile (07-autocheck-outline.md): timeout 500 ms.
        # Прод — консервативнее (5s по умолчанию), тоже переопределяемо.
        default_timeout = 0.5 if test_profile else 5.0
        timeout_seconds = float(environ.get("PROVIDER_TIMEOUT_SECONDS", default_timeout))
        return cls(url=url, timeout_seconds=timeout_seconds)


@dataclass(frozen=True)
class AdapterConfig:
    """Конфигурация receipt-адаптера.

    Все обязательные поля (capability, token, hmac_secret, receipt_api_url)
    идут до max_body_size с default — порядок корректный.
    """
    capability: str
    token: str
    hmac_secret: str
    receipt_api_url: str
    max_body_size: int = 64 * 1024  # 64 KiB
    # Проверка readiness: "для adapter — gateway" (Live/ready и шесть метрик).
    # Не PROVIDER_URL и не PostgreSQL — adapter в принципе не имеет
    # PostgreSQL credentials, а provider для него не critical dependency.
    gateway_url: str = "http://gateway:8080"

    @classmethod
    def from_env(cls) -> "AdapterConfig":
        capability = environ.get("PROVIDER_CALLBACK_CAPABILITY")
        token = environ.get("PROVIDER_CALLBACK_TOKEN")
        hmac_secret = environ.get("PROVIDER_HMAC_SECRET")
        receipt_api_url = environ.get("RECEIPT_API_URL", "http://gateway:8080/api/receipt/accept")
        gateway_url = environ.get("GATEWAY_URL", "http://gateway:8080")

        if not capability:
            raise ValueError("PROVIDER_CALLBACK_CAPABILITY is required")
        if not token:
            raise ValueError("PROVIDER_CALLBACK_TOKEN is required")
        if not hmac_secret:
            raise ValueError("PROVIDER_HMAC_SECRET is required")

        return cls(
            capability=capability,
            token=token,
            hmac_secret=hmac_secret,
            receipt_api_url=receipt_api_url,
            gateway_url=gateway_url,
        )


@dataclass(frozen=True)
class DispatcherConfig:
    """Конфигурация outbox-dispatcher.

    owner без default идёт первым, остальные — со значениями после него.
    """
    owner: str
    poll_interval_seconds: float = 0.5
    claim_limit: int = 10

    @classmethod
    def from_env(cls, test_profile: bool = False) -> "DispatcherConfig":
        owner = environ.get("OUTBOX_OWNER", "outbox-dispatcher")
        default_poll = 0.2 if test_profile else 0.5
        poll_interval_seconds = float(environ.get("OUTBOX_POLL_INTERVAL_SECONDS", default_poll))
        claim_limit = int(environ.get("OUTBOX_CLAIM_LIMIT", 10))
        return cls(owner=owner, poll_interval_seconds=poll_interval_seconds, claim_limit=claim_limit)


@dataclass(frozen=True)
class ReconcilerConfig:
    """Конфигурация inbox-reconciler — раньше задавалась позиционными
    default-аргументами прямо в __main__.py; вынесена сюда, чтобы
    reconciler получал COURSE_INSTANCE_ID/health_port тем же способом,
    что dispatcher и adapter (симметрия неделя-4 конфигурации).
    """
    poll_interval_seconds: float = 0.5
    batch_limit: int = 100

    @classmethod
    def from_env(cls, test_profile: bool = False) -> "ReconcilerConfig":
        default_poll = 0.2 if test_profile else 0.5
        poll_interval_seconds = float(environ.get("INBOX_POLL_INTERVAL_SECONDS", default_poll))
        batch_limit = int(environ.get("INBOX_BATCH_LIMIT", 100))
        return cls(poll_interval_seconds=poll_interval_seconds, batch_limit=batch_limit)
