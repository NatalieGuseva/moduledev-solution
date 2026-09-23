#!/bin/sh
# Одношаговый bootstrap: миграции + публикация/активация payment-flows.
# publish/activate идемпотентны (см. Cli/Commands/FlowCommands.cs), поэтому
# скрипт безопасно перезапускать на каждый `docker compose up` этого сервиса.
set -e

dotnet Cli.dll migration apply /app/Migrations/ChecksummedMigrations

dotnet Cli.dll flow publish /app/contracts/course-1/payment-processing-v1.flow.yaml
dotnet Cli.dll flow activate payment-processing --version 1

dotnet Cli.dll flow publish /app/contracts/course-1/payment-review-v1.flow.yaml
dotnet Cli.dll flow activate payment-review --version 1