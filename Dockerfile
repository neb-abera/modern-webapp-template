# syntax=docker/dockerfile:1

#
# Single source of truth for the Node toolchain. Every stage that needs Node
# derives from this image, so one Dependabot bump moves them all together.
# bookworm-slim (glibc 2.36) stays binary-compatible with the Ubuntu-based
# .NET SDK image the dev stage copies Node into.
#
FROM node:26-bookworm-slim@sha256:367679cf9792759492a486e4aa4b421764d71a9546a6dae8aab81a99eb797b3e AS node-base

#
# Client build
#
FROM node-base AS client-build
WORKDIR /build/client
COPY client/package.json client/package-lock.json ./
RUN npm ci
COPY client/ ./
RUN npm run build

#
# Server build
#
# The 10.0 tags here and on the runtime image must move in lockstep with
# <TargetFramework> in server/Directory.Build.props. Dependabot bumps these
# tags but never the TargetFramework — the dotnet-major-upgrade workflow
# (scripts/check-dotnet-major.sh) makes the cross-major jump.
#
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:e1ffd2a92ae84c1291bc1b6887501f8af98e6331e7af6d4c8d37168c5e87a64c AS server-build
WORKDIR /build/server
COPY server/ ./
# ReadyToRun precompiles IL for faster cold starts (Container Apps scale
# from zero); see docs/performance.md for the further Native AOT option.
RUN dotnet publish Api/Api.csproj -c Release -o /out -p:PublishReadyToRun=true -p:RestoreLockedMode=true

#
# Development toolchain (used by `make shell` and the dev compose profile):
# .NET SDK plus Node, running as the image's non-root user. Node comes from
# node-base above rather than a package repository, so the dev toolchain can
# never drift from the version the client is built with.
#
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:e1ffd2a92ae84c1291bc1b6887501f8af98e6331e7af6d4c8d37168c5e87a64c AS dev
COPY --from=node-base /usr/local/bin/node /usr/local/bin/node
COPY --from=node-base /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
USER app
WORKDIR /work

#
# Production runtime: distroless-style chiseled image, non-root by default,
# serving the API and the built client from one container.
#
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled@sha256:0839314d08bb65da369135389a5d8291f75ace587fbb0488f469eb92c62eef68 AS runtime
WORKDIR /app
COPY --from=server-build /out ./
COPY --from=client-build /build/client/dist ./wwwroot
EXPOSE 8080
# Chiseled images carry no shell or curl, so the healthcheck re-enters the
# app binary in --healthcheck mode (see Program.cs), which probes /healthz.
# Compose inherits this, so `depends_on: condition: service_healthy` and
# `docker compose up --wait` work against the production image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["dotnet", "Api.dll", "--healthcheck"]
ENTRYPOINT ["dotnet", "Api.dll"]
