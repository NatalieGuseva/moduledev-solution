FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY ["Api/Api.csproj", "Api/"]
COPY ["Common/Common.csproj", "Common/"]
RUN dotnet restore "Api/Api.csproj"

COPY . .
WORKDIR "/src/Api"
RUN dotnet build "Api.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "Api.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
EXPOSE 8080

# ✅ Устанавливаем curl для healthcheck.
# libgssapi-krb5-2 — Npgsql на Linux пытается динамически подгрузить
# libgssapi_krb5.so.2 при установлении соединения; без неё это ошибка
# на каждой попытке подключения. Это НЕ libkrb5-3 (тот даёт только
# libkrb5.so.3, проверено на реальной системе) — libgssapi-krb5-2 тянет
# libkrb5-3 как зависимость сам.
RUN apt-get update && apt-get install -y curl libgssapi-krb5-2 && rm -rf /var/lib/apt/lists/*

COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Api.dll"]