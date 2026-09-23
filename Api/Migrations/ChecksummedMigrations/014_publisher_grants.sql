-- ============================================================
-- Миграция 014: гранты для course_publisher
-- ============================================================
--
-- course_publisher — LOGIN-роль (создана заранее init-скриптом
-- postgres-init/00-bootstrap-roles.sh), под которой Cli/Program.cs
-- подключается для "action publish/list/activate/disable" и
-- "flow publish/activate/validate/start/signal/finish". В отличие от
-- course_migrator у неё нет CREATEROLE и нет членства в course_owner —
-- только точечные GRANT ниже, ровно под то, что эти команды реально
-- делают (см. Cli/Program.cs HandlePublish/HandleList/HandleActivate/
-- HandleDisable и Cli/Commands/FlowCommands.cs).
--
-- Проверено реальным прогоном на PG16: подключение под course_publisher,
-- INSERT в workflow.flow_definition/flow_version/task_definition/
-- step_definition/transition_definition, UPDATE course.action_catalog,
-- EXECUTE course.publish_action/workflow.start_process/receive_signal/
-- finish_job — всё проходит; попытка что-то ещё (например, DML в
-- delivery.outbox или course.operations) — запрещена, как и должно быть.

-- Без USAGE на сами схемы табличные/функциональные GRANT ниже бесполезны
-- (Postgres проверяет оба уровня отдельно) — course_publisher никогда не
-- получал доступ к этим двум схемам раньше вообще.
GRANT USAGE ON SCHEMA course TO course_publisher;
GRANT USAGE ON SCHEMA workflow TO course_publisher;

-- action publish: единственная точка входа для регистрации/обновления
-- action_catalog — обычный INSERT ... ON CONFLICT ... DO UPDATE внутри
-- SECURITY DEFINER функции, publisher нужен только EXECUTE на неё.
GRANT EXECUTE ON FUNCTION course.publish_action(
    text, text, integer, text, text, text, jsonb, jsonb, jsonb, jsonb, text, text, integer, boolean
) TO course_publisher;

-- action list/activate/disable: Cli/Program.cs делает это raw SQL
-- напрямую (SELECT * FROM course.action_catalog / UPDATE ... SET
-- enabled=.../is_default=...), а не через функцию — поэтому нужен
-- прямой DML на саму таблицу, не только EXECUTE.
GRANT SELECT, UPDATE ON course.action_catalog TO course_publisher;

-- flow publish/activate: FlowCommands.cs пишет определение карты
-- (flow_definition/flow_version) и её шаги/переходы (task_definition/
-- step_definition/transition_definition) прямыми INSERT/UPDATE, минуя
-- функции — в отличие от action publish, для карт нет отдельной
-- SECURITY DEFINER обёртки, вся валидация (FlowValidator) уже сделана
-- в C# ДО этих операторов.
GRANT SELECT, INSERT, UPDATE ON workflow.flow_definition TO course_publisher;
GRANT SELECT, INSERT, UPDATE ON workflow.flow_version TO course_publisher;
GRANT SELECT, INSERT ON workflow.task_definition TO course_publisher;
GRANT SELECT, INSERT ON workflow.step_definition TO course_publisher;
GRANT SELECT, INSERT ON workflow.transition_definition TO course_publisher;

-- flow validate/publish читают action_catalog, чтобы проверить, что
-- каждый action-шаг карты ссылается на существующий зарегистрированный
-- action (та самая межмодульная проверка зависимостей).
GRANT SELECT ON course.action_catalog TO course_publisher;

-- flow start/signal/finish — трюковые локальные команды для проверки
-- workflow-ядра (см. student-facing комментарий в FlowCommands.cs:
-- "предназначена для проверки workflow-ядра... пишет workflow_signal
-- напрямую"), используют ту же CLI-роль, что публикация карт — отдельной
-- роли под них заводить не стали, это те же "доверенные локальные
-- инструменты автора карты", а не runtime-путь.
GRANT EXECUTE ON FUNCTION workflow.start_process(text, text, jsonb) TO course_publisher;
GRANT EXECUTE ON FUNCTION workflow.receive_signal(uuid, text, text, jsonb) TO course_publisher;
GRANT EXECUTE ON FUNCTION workflow.finish_job(uuid, text, bigint, text, jsonb) TO course_publisher;
