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

COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "Workflow.Worker.dll"]
