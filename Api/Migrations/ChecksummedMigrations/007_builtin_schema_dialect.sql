-- ============================================================
-- Миграция 007: Явный dialect ($schema) во встроенных манифестах
-- ============================================================
--
-- request_schema/response_schema для payment.request v1 и operation.get v1
-- (003_insert_actions.sql) не декларировали "$schema" — то есть формально
-- не указывали, по какому dialect'у JSON Schema их валидировать. Раз файл
-- 003 уже применён, менять его нельзя: checksum в course.migration_history
-- не совпадёт и "cli migration apply" вернёт manifest.conflict. Поэтому
-- дополняем уже вставленные строки новой миграцией, а не правим 003.
SET ROLE course_owner;

UPDATE course.action_catalog
SET request_schema = jsonb_set(
        request_schema, '{$schema}',
        '"https://json-schema.org/draft/2020-12/schema"'::jsonb, true
    ),
    response_schema = jsonb_set(
        response_schema, '{$schema}',
        '"https://json-schema.org/draft/2020-12/schema"'::jsonb, true
    )
WHERE (module, action, version) IN (('payment', 'request', 1), ('operation', 'get', 1));

RESET ROLE;
