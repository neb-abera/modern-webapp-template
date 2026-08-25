# syntax=docker/dockerfile:1

#
# Client build
#
FROM node:24-alpine AS client-build
WORKDIR /build/client
COPY client/package.json client/package-lock.json ./
RUN npm ci
COPY client/ ./
RUN npm run build

#
# Server build
#
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS server-build
WORKDIR /build/server
COPY server/ ./
RUN dotnet publish Api/Api.csproj -c Release -o /out

#
# Development toolchain (used by `make shell` and the dev compose profile):
# .NET SDK plus Node, running as the image's non-root user.
#
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS dev
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*
USER app
WORKDIR /work

#
# Production runtime: distroless-style chiseled image, non-root by default,
# serving the API and the built client from one container.
#
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS runtime
WORKDIR /app
COPY --from=server-build /out ./
COPY --from=client-build /build/client/dist ./wwwroot
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
