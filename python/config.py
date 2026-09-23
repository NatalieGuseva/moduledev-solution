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
class ProviderConfig:
    """Конфигурация провайдера.

    Здесь всё корректно: url без default идёт первым, timeout_seconds
    со значением — после него.
    """
    url: str
    timeout_seconds: float = 5.0

    @classmethod
    def from_env(cls) -> "ProviderConfig":
        url = environ.get("PROVIDER_URL", "http://provider-simulator:8081")
        return cls(url=url)


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

    @classmethod
    def from_env(cls) -> "AdapterConfig":
        capability = environ.get("PROVIDER_CALLBACK_CAPABILITY")
        token = environ.get("PROVIDER_CALLBACK_TOKEN")
        hmac_secret = environ.get("PROVIDER_HMAC_SECRET")
        receipt_api_url = environ.get("RECEIPT_API_URL", "http://gateway:8080/api/receipt/accept")

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
    def from_env(cls) -> "DispatcherConfig":
        owner = environ.get("OUTBOX_OWNER", "outbox-dispatcher")
        return cls(owner=owner)