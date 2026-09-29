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
        # docs/configuration.md: COURSE_PROVIDER_TIMEOUT_MS в миллисекундах,
        # 500 в test profile; вне test profile — 5000.
        default_timeout_ms = 500 if test_profile else 5000
        timeout_ms = int(environ.get("COURSE_PROVIDER_TIMEOUT_MS", default_timeout_ms))
        timeout_seconds = timeout_ms / 1000.0
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
    lease/retry-параметры PostgreSQL-функции читают из параметров сессии
    (см. session_settings и миграцию 021): сигнатуры claim_outbox/fail_outbox
    не меняются, а COURSE_OUTBOX_* реально влияют на поведение.
    """
    owner: str
    poll_interval_seconds: float = 0.5
    claim_limit: int = 10
    lease_ms: int = 30000
    max_attempts: int = 4
    backoff_base_ms: int = 200
    backoff_max_ms: int = 800
    jitter_max_ms: int = 100

    @classmethod
    def from_env(cls, test_profile: bool = False) -> "DispatcherConfig":
        owner = environ.get("OUTBOX_OWNER", "outbox-dispatcher")
        # COURSE_OUTBOX_POLL_MS: 100 в test profile (docs/configuration.md).
        poll_ms = int(environ.get("COURSE_OUTBOX_POLL_MS", 100 if test_profile else 500))
        claim_limit = int(environ.get("OUTBOX_CLAIM_LIMIT", 10))
        return cls(
            owner=owner,
            poll_interval_seconds=poll_ms / 1000.0,
            claim_limit=claim_limit,
            lease_ms=int(environ.get("COURSE_OUTBOX_LEASE_MS", 2000 if test_profile else 30000)),
            max_attempts=int(environ.get("COURSE_OUTBOX_MAX_ATTEMPTS", 4)),
            backoff_base_ms=int(environ.get("COURSE_OUTBOX_BACKOFF_BASE_MS", 200)),
            backoff_max_ms=int(environ.get("COURSE_OUTBOX_BACKOFF_MAX_MS", 800)),
            jitter_max_ms=int(environ.get("COURSE_OUTBOX_JITTER_MAX_MS", 100)),
        )

    @property
    def session_settings(self) -> dict:
        """Параметры сессии PostgreSQL (GUC), которые читают claim_outbox/fail_outbox."""
        return {
            "course.outbox_lease_ms": str(self.lease_ms),
            "course.outbox_max_attempts": str(self.max_attempts),
            "course.outbox_backoff_base_ms": str(self.backoff_base_ms),
            "course.outbox_backoff_max_ms": str(self.backoff_max_ms),
            "course.outbox_jitter_max_ms": str(self.jitter_max_ms),
        }


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
        # COURSE_INBOX_POLL_MS: 500 (docs/configuration.md).
        poll_interval_seconds = int(environ.get("COURSE_INBOX_POLL_MS", 500)) / 1000.0
        batch_limit = int(environ.get("INBOX_BATCH_LIMIT", 100))
        return cls(poll_interval_seconds=poll_interval_seconds, batch_limit=batch_limit)
