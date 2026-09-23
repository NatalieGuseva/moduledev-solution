-- ============================================================
-- Миграция 010: Схема delivery — Outbox/Inbox таблицы и роли
-- outbox_dispatcher / inbox_reconciler (неделя 3, Python-периметр)
-- ============================================================
--
-- Реальный LOGIN и пароль этим ролям выставляет postgres-init
-- (postgres-init/00-bootstrap-roles.sh) при первой инициализации тома,
-- из COURSE_OUTBOX_PASSWORD/COURSE_INBOX_PASSWORD — тех же переменных,
-- которые checker передаёт python-сервисам synthetic-значением.
-- Здесь (миграция — статичный .sql без доступа к env) роль только
-- создаётся как NOLOGIN fallback, если её почему-то ещё нет, и пароль
-- НЕ трогается, если роль уже существует — иначе миграция перезапишет
-- synthetic-пароль локальным placeholder'ом и сломает аутентификацию
-- под checker (именно так и было раньше — отсюда ошибка).
-- GRANT EXECUTE на конкретные функции — уже в 011_delivery_functions.sql,
-- после того как сами функции появятся.

-- 1. Схема
CREATE SCHEMA IF NOT EXISTS delivery;

-- 2. Роли — fallback-создание, пароль ставит postgres-init (см. выше)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'outbox_dispatcher') THEN
        CREATE ROLE outbox_dispatcher NOLOGIN;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'inbox_reconciler') THEN
        CREATE ROLE inbox_reconciler NOLOGIN;
    END IF;
END
$$;

-- ============================================================
-- 3. delivery.outbox — исходящие платежи к provider.
--    external_request_id — стабильный идемпотентный ключ, который
--    отправляется provider'у как Idempotency-Key И как тело
--    operationId (по заданию provider требует их равенства).
--    UNIQUE на нём же гарантирует "одна попытка prepare_external —
--    одна Outbox-запись", даже если payment.prepare_external
--    вызовут повторно с тем же executionId.
-- ============================================================
CREATE TABLE delivery.outbox (
    outbox_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_id UUID NOT NULL,
    external_request_id TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    correlation_id UUID NOT NULL DEFAULT gen_random_uuid(),
    amount NUMERIC(19,2) NOT NULL,
    currency TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN (
        'PENDING', 'LEASED', 'RETRY_WAIT', 'DELIVERED', 'CONFIRMED', 'DEAD'
    )) DEFAULT 'PENDING',
    lease_owner TEXT,
    lease_version BIGINT NOT NULL DEFAULT 0,
    lease_until TIMESTAMPTZ,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ,
    last_error_code TEXT,
    provider_payment_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    confirmed_at TIMESTAMPTZ,
    CONSTRAINT uq_outbox_external_request_id UNIQUE (external_request_id)
);

COMMENT ON COLUMN delivery.outbox.state IS
    'PENDING/RETRY_WAIT/LEASED — рабочие состояния dispatcher''а (claim/succeed/fail_outbox). '
    'DELIVERED — provider принял (202 ACCEPTED), ждём receipt. '
    'CONFIRMED — проставляется отдельно из receipt.accept (payment-домен), когда receipt применён; '
    'succeed_outbox/fail_outbox НИКОГДА не трогают и не регрессируют это состояние. '
    'DEAD — терминальная non-retryable ошибка или исчерпаны попытки (имя состояния зафиксировано '
    '07-autocheck-outline.md; настоящий dead-letter/несколько dispatcher — неделя 4).';

CREATE INDEX idx_outbox_claimable
    ON delivery.outbox (next_attempt_at)
    WHERE state IN ('PENDING', 'RETRY_WAIT');

CREATE INDEX idx_outbox_state ON delivery.outbox (state);
CREATE INDEX idx_outbox_operation_id ON delivery.outbox (operation_id);

-- ============================================================
-- 4. delivery.inbox — принятые receipt'ы, ожидающие/применённые
--    как workflow-сигнал.
-- ============================================================
CREATE TABLE delivery.inbox (
    message_id TEXT PRIMARY KEY,
    external_request_id TEXT NOT NULL,
    process_id UUID NOT NULL,
    signal_type TEXT NOT NULL DEFAULT 'payment.receipt',
    body JSONB NOT NULL,
    body_hash TEXT NOT NULL,
    outcome TEXT,
    state TEXT NOT NULL CHECK (state IN ('RECEIVED', 'APPLIED')) DEFAULT 'RECEIVED',
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_at TIMESTAMPTZ
);

COMMENT ON COLUMN delivery.inbox.body_hash IS
    'SHA-256 от ТОЧНЫХ полученных HTTP body bytes. Обязан приходить от вызывающей '
    'стороны (receipt.accept) как готовый параметр, а не пересчитываться из JSONB '
    'здесь — jsonb::text не гарантирует тот же порядок/форматирование ключей, что '
    'исходные подписанные bytes, из-за чего сравнение "тот же messageId, другой body" '
    'может ошибочно не сработать или сработать не на то.';

CREATE INDEX idx_inbox_claimable
    ON delivery.inbox (received_at)
    WHERE state = 'RECEIVED';

CREATE INDEX idx_inbox_external_request_id ON delivery.inbox (external_request_id);

-- ============================================================
-- Владение и права
-- ============================================================
ALTER SCHEMA delivery OWNER TO course_owner;
ALTER TABLE delivery.outbox OWNER TO course_owner;
ALTER TABLE delivery.inbox OWNER TO course_owner;

COMMENT ON SCHEMA delivery IS 'Outbox/Inbox периметр Python-сервисов (неделя 3): транспорт, а не предметная логика';
COMMENT ON TABLE delivery.outbox IS 'Исходящие платежи к provider — обрабатывается Python outbox-dispatcher через claim/succeed/fail_outbox';
COMMENT ON TABLE delivery.inbox IS 'Входящие receipt (после adapter) — обрабатывается Python inbox-reconciler через reconcile_inbox';