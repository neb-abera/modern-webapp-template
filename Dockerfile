# syntax=docker/dockerfile:1

#
# Single source of truth for the Node toolchain. Every stage that needs Node
# derives from this image, so one Dependabot bump moves them all together.
# bookworm-slim (glibc 2.36) stays binary-compatible with the Ubuntu-based
# .NET SDK image the dev stage copies Node into.
#
FROM node:26-bookworm-slim@sha256:c8fedd782bcd1b68d8a7d1ed2577b5f820eba820871323f605292651ff11e3c6 AS node-base

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
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:2fa828c68761b1b8c23d7662dc134421b9d3b59fe1425fdbc80804e390cdb24d AS server-build
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
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:2fa828c68761b1b8c23d7662dc134421b9d3b59fe1425fdbc80804e390cdb24d AS dev
COPY --from=node-base /usr/local/bin/node /usr/local/bin/node
COPY --from=node-base /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
USER app
WORKDIR /work

#
# The client type generator: openapi-typescript and the TypeScript 5 it needs,
# from their own manifest and lockfile (tools/api-types/package.json says why
# they cannot share the client's). Only node_modules leaves this stage.
#
FROM node-base AS apitypes
WORKDIR /work/tools/api-types
COPY tools/api-types/package.json tools/api-types/package-lock.json ./
RUN npm ci

#
# Everything that regenerates the API contract: the .NET SDK, whose build
# emits server/Api/openapi.json, and the generator's tree for the client
# types. `make contract` runs this with the checkout mounted at /work.
#
FROM dev AS contract
COPY --from=apitypes --chown=app:app /work/tools/api-types/node_modules /work/tools/api-types/node_modules
CMD ["sh", "-c", "dotnet build server/Api -c Release -p:RestoreLockedMode=true && cd client && npm run generate:api-types"]

#
# Production runtime: distroless-style chiseled image, non-root by default,
# serving the API and the built client from one container.
#
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled@sha256:9651fa59abcdf177c30392cb44a820605ca5d618429ab37acbf6e7c644510b02 AS runtime
WORKDIR /app
COPY --from=server-build /out ./
COPY --from=client-build /build/client/dist ./wwwroot
# The chiseled base already defaults to its non-root user (uid 1654, exported
# as APP_UID), but only implicitly. Declare it, so the claim survives a base
# image change — and verify.sh's smoke check asserts the built image's
# Config.User is a non-zero numeric uid, which fails if this ever reverts.
USER $APP_UID
EXPOSE 8080
# Chiseled images carry no shell or curl, so the healthcheck re-enters the
# app binary in --healthcheck mode (see Program.cs), which probes /healthz.
# Compose inherits this, so `depends_on: condition: service_healthy` and
# `docker compose up --wait` work against the production image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["dotnet", "Api.dll", "--healthcheck"]
ENTRYPOINT ["dotnet", "Api.dll"]
