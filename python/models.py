# python/models.py
from dataclasses import dataclass
from typing import Optional
from uuid import UUID
from datetime import datetime
from enum import Enum


class OutboxState(str, Enum):
    PENDING = "PENDING"
    LEASED = "LEASED"
    RETRY_WAIT = "RETRY_WAIT"
    DELIVERED = "DELIVERED"
    DEAD = "DEAD"
    CONFIRMED = "CONFIRMED"


class ReceiptOutcome(str, Enum):
    COMPLETED = "COMPLETED"
    REJECTED = "REJECTED"


class InboxState(str, Enum):
    RECEIVED = "RECEIVED"
    APPLIED = "APPLIED"
    CONFLICT = "CONFLICT"


@dataclass
class OutboxClaim:
    """Запись из delivery.claim_outbox."""
    outbox_id: UUID
    lease_version: int
    external_request_id: str
    correlation_id: UUID
    amount: str
    currency: str


@dataclass
class ProviderPaymentRequest:
    """Запрос к provider-simulator."""
    operation_id: str
    amount: str
    currency: str
    
    def to_json(self) -> dict:
        return {
            "operationId": self.operation_id,
            "amount": self.amount,
            "currency": self.currency
        }


@dataclass
class ProviderCallback:
    """Legacy callback от provider v0.2.0."""
    provider_payment_id: str
    operation_id: str
    result: str
    message: str
    occurred_at: str
    
    @classmethod
    def from_dict(cls, data: dict) -> "ProviderCallback":
        """Строгая валидация с reject unknown fields."""
        allowed = {"providerPaymentId", "operationId", "result", "message", "occurredAt"}
        unknown = set(data.keys()) - allowed
        if unknown:
            raise ValueError(f"Unknown fields: {unknown}")
        
        # Проверка CR/LF в строковых полях
        for field in ("providerPaymentId", "operationId", "occurredAt", "message"):
            value = data.get(field)
            if value and ("\r" in str(value) or "\n" in str(value)):
                raise ValueError(f"CR/LF not allowed in {field}")
        
        return cls(
            provider_payment_id=data["providerPaymentId"],
            operation_id=data["operationId"],
            result=data["result"],
            message=data.get("message", ""),
            occurred_at=data["occurredAt"]
        )


@dataclass
class ReceiptV1:
    """Нормализованный receipt version 1."""
    external_request_id: str
    message_id: str
    occurred_at: str
    outcome: str
    provider_payment_id: str
    version: int = 1
    
    @classmethod
    def from_legacy(cls, callback: ProviderCallback) -> "ReceiptV1":
        """Преобразует legacy callback в receipt v1."""
        if callback.result not in ("COMPLETED", "REJECTED"):
            raise ValueError(f"Invalid result: {callback.result}")
        
        return cls(
            external_request_id=callback.operation_id,
            message_id=callback.provider_payment_id,
            occurred_at=callback.occurred_at,
            outcome=callback.result,
            provider_payment_id=callback.provider_payment_id
        )
    
    def to_compact_json_bytes(self) -> bytes:
        """Сериализует в compact JSON с sorted keys, без BOM и LF."""
        import json
        return json.dumps(
            {
                "externalRequestId": self.external_request_id,
                "messageId": self.message_id,
                "occurredAt": self.occurred_at,
                "outcome": self.outcome,
                "providerPaymentId": self.provider_payment_id,
                "version": self.version
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True
        ).encode("utf-8")