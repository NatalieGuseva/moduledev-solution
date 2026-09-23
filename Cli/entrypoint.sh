#!/bin/sh
# Bootstrap + entrypoint для CLI.
#
# Если переданы аргументы (например, `cli action publish ...` от checker'а),
# сразу exec'аем их в dotnet Cli.dll, ничего не делая до этого.
#
# Если аргументов нет (обычный `docker compose up` сервиса cli),
# делаем одноразовый bootstrap: миграции + публикация/активация payment-flows.
#
# Весь диагностический вывод bootstrap идёт в stderr, чтобы не мешать
# JSON-ответу CLI в stdout (checker парсит stdout как одну JSON-строку).
set -e

if [ "$#" -gt 0 ]; then
  exec dotnet Cli.dll "$@"
fi

dotnet Cli.dll migration apply /app/Migrations/ChecksummedMigrations >&2

dotnet Cli.dll flow publish /app/contracts/course-1/payment-processing-v1.flow.yaml >&2
dotnet Cli.dll flow activate payment-processing --version 1 >&2

dotnet Cli.dll flow publish /app/contracts/course-1/payment-review-v1.flow.yaml >&2
dotnet Cli.dll flow activate payment-review --version 1 >&2