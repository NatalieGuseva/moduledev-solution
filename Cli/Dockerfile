FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Копируем файлы проектов для восстановления зависимостей
COPY ["Cli/Cli.csproj", "Cli/"]
COPY ["Common/Common.csproj", "Common/"]
RUN dotnet restore "Cli/Cli.csproj"

# Копируем весь исходный код
COPY . .

# Собираем проект
WORKDIR "/src/Cli"
RUN dotnet build "Cli.csproj" -c Release -o /app/build

# Публикуем
FROM build AS publish
RUN dotnet publish "Cli.csproj" -c Release -o /app/publish /p:UseAppHost=false

# Финальный образ
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends libkrb5-3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=publish /app/publish .
COPY ["Api/Migrations", "Migrations"]
ENTRYPOINT ["dotnet", "Cli.dll"]