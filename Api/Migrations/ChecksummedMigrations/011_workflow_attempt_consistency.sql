-- ============================================================
-- Миграция 011: attempt_count синхронизирован с task_attempt,
-- отдельный failure_count под бюджет retry, unique constraint
-- ============================================================
--
-- До этой миграции job.attempt_count и количество строк
-- workflow.task_attempt могли расходиться: claim_jobs заводил новую
-- attempt (в т.ч. при реклейме протухшего лизинга) и НЕ трогал
-- attempt_count, а finish_job/fail_job инкрементировали attempt_count
-- только на РЕАЛЬНОМ разрешении попытки (успех/провал). В результате
-- у job с несколькими stale-реклеймами attempt_count оказывался меньше
-- реального числа строк task_attempt — разные проекции показывали
-- разную историю исполнения одной и той же job.
--
-- Разводим это явно на два разных счётчика вместо одного:
-- - attempt_count — теперь растёт на КАЖДЫЙ claim (в т.ч. реклейм
--   протухшего лизинга), синхронно с task_attempt.attempt_number.
--   Отражает "сколько раз job вообще забирали".
-- - failure_count (новый) — растёт только там, где раньше рос
--   attempt_count: при реальном доменном провале (retryable → RETRY_WAIT,
--   исчерпан бюджет/non-retryable → DEAD). Отражает "сколько раз job
--   реально не удалась по вине предметной логики", и именно он
--   участвует в проверке max_attempts — иначе job, которой просто не
--   везёт с лизингом (инфраструктурная заминка, не её вина), могла бы
--   преждевременно уйти в DEAD, ни разу не провалившись по-настоящему.
ALTER TABLE workflow.workflow_job
    ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0;

-- Явная проверка согласованности на уровне схемы: attempt_number обязан
-- быть уникален в рамках одной job — при корректной работе claim_jobs
-- (FOR UPDATE SKIP LOCKED, MAX(attempt_number)+1 внутри той же
-- транзакции, что и UPDATE lease-полей) это и так гарантировано логикой,
-- но constraint защищает от будущей регрессии, а не только от текущего
-- отсутствия бага.
ALTER TABLE workflow.task_attempt
    ADD CONSTRAINT task_attempt_job_attempt_number_key UNIQUE (job_id, attempt_number);
