# ================================
# Этап 1: Сборка (Build)
# ================================
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Копируем файлы проектов для восстановления зависимостей
COPY ["Cli/Cli.csproj", "Cli/"]
COPY ["Common/Common.csproj", "Common/"]

# Восстанавливаем зависимости
RUN dotnet restore "Cli/Cli.csproj"

# Копируем весь исходный код
COPY . .

# Собираем проект
WORKDIR "/src/Cli"
RUN dotnet build "Cli.csproj" -c Release -o /app/build

# ================================
# Этап 2: Публикация (Publish)
# ================================
FROM build AS publish
RUN dotnet publish "Cli.csproj" -c Release -o /app/publish /p:UseAppHost=false

# ================================
# Этап 3: Финальный образ (Runtime)
# ================================
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app

# Устанавливаем библиотеки Kerberos/GSSAPI для Npgsql.
# Npgsql 8+ требует libgssapi_krb5.so.2 даже для scram-sha-256 аутентификации.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libkrb5-3 \
        libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/*

# Копируем опубликованные файлы
COPY --from=publish /app/publish .

ENTRYPOINT ["dotnet", "Cli.dll"]