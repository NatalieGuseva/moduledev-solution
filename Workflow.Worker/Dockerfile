FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY ["Workflow.Worker/Workflow.Worker.csproj", "Workflow.Worker/"]
COPY ["Common/Common.csproj", "Common/"]
RUN dotnet restore "Workflow.Worker/Workflow.Worker.csproj"

COPY . .
WORKDIR "/src/Workflow.Worker"
RUN dotnet build "Workflow.Worker.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "Workflow.Worker.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app

# Npgsql на Linux при установлении соединения пытается динамически
# подгрузить libgssapi_krb5.so.2 для GSSAPI-негоциации. Без неё это
# ошибка на каждой попытке подключения. Пакет называется
# libgssapi-krb5-2 (НЕ libkrb5-3 — тот даёт только libkrb5.so.3,
# проверено на реальной системе); libkrb5-3 подтягивается им как
# зависимость автоматически.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Workflow.Worker.dll"]
