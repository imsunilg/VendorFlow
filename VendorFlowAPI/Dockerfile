# VendorFlow API image. Build from the repository root (the SQL scripts of VendorFlowDB are embedded into the assembly):
#   docker build -f VendorFlowAPI/Dockerfile -t vendorflow-api .
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY VendorFlowAPI/ VendorFlowAPI/
COPY VendorFlowDB/ VendorFlowDB/
RUN dotnet publish VendorFlowAPI/VendorFlow.API/VendorFlow.API.csproj -c Release -o /app --no-self-contained

FROM mcr.microsoft.com/dotnet/aspnet:9.0
# QuestPDF (purchase order PDF) needs fontconfig.
RUN apt-get update && apt-get install -y --no-install-recommends libfontconfig1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
RUN mkdir -p /data/storage && chown -R app:app /data
ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    Storage__Path=/data/storage
USER app
EXPOSE 8080
ENTRYPOINT ["dotnet", "VendorFlow.API.dll"]
