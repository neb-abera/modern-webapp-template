# syntax=docker/dockerfile:1

#
# Single source of truth for the Node toolchain. Every stage that needs Node
# derives from this image, so one Dependabot bump moves them all together.
# trixie-slim (glibc 2.41) stays binary-compatible with the Ubuntu 26.04
# .NET SDK image (glibc 2.43) the dev stage copies Node into.
#
FROM node:26-trixie-slim@sha256:0d1e33586362bb9e608c4e751e7a9e7edb55c9ac11461ed5666af696cc461dd4 AS node-base

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
# The 11.0 tags here and on the runtime image must move in lockstep with
# <TargetFramework> in server/Directory.Build.props. Dependabot bumps these
# tags but never the TargetFramework — the dotnet-major-upgrade workflow
# (scripts/check-dotnet-major.sh) makes the cross-major jump.
#
FROM mcr.microsoft.com/dotnet/sdk:11.0-resolute@sha256:bfabf51e74c5a7cf2fc4eac852145db86f4867d475257d809518d6a2b0fe71e1 AS server-build
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
FROM mcr.microsoft.com/dotnet/sdk:11.0-resolute@sha256:bfabf51e74c5a7cf2fc4eac852145db86f4867d475257d809518d6a2b0fe71e1 AS dev
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

# Prose linter, for scripts/check-prose.sh. Never built into anything: the
# stage exists so the image is a FROM line Dependabot sees and bumps, and the
# script reads it from here rather than pinning a version of its own.
FROM jdkato/vale:v3.24.0@sha256:f5a09410093936d4919d868120786da9789e2652ac321c66a895403eca020ae4 AS vale

# The scanners CI runs, for their versions only: trivy-action and
# sbom-action take a version input, and these FROM lines are what
# Dependabot bumps. Nothing is built from them.
FROM aquasec/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222 AS trivy
FROM anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa AS syft

# Workflow and script linter, for `make lint` and the CI lint job. Never
# built into anything, like the vale stage: the image carries actionlint and
# the shellcheck it runs on embedded run: blocks, and one FROM line here is
# what Dependabot bumps.
FROM rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 AS actionlint

# The same rules, on the pages a reader is given rather than on the Markdown
# beside them. A leaf: nothing ships from here.
#
# The fixtures first, every time: the failing one must fail and the clean one
# must pass, so a rule or a config path that has stopped working is caught
# here rather than trusted. Then every prerendered page. spa.html is the
# empty shell the server falls back to and carries no copy.
#
#   docker build --target pageprose .
#   make prose
FROM vale AS pageprose
COPY --from=client-build /build/client/dist /dist
COPY [".vale.ini", "/prose/.vale.ini"]
COPY [".vale/", "/prose/.vale/"]
RUN ! vale --config=/prose/.vale.ini --output=line /prose/.vale/fixtures/fails.md > /dev/null \
    && vale --config=/prose/.vale.ini --output=line /prose/.vale/fixtures/passes.md \
    && find /dist -name '*.html' ! -name spa.html -print0 \
    | xargs -0 vale --config=/prose/.vale.ini --output=line

#
# Production runtime: distroless-style chiseled image, non-root by default,
# serving the API and the built client from one container.
#
FROM mcr.microsoft.com/dotnet/aspnet:11.0-resolute-chiseled@sha256:f502def1917cec1c8e401a65b5866704dd51ca99857f139ff11bf7f7685d7fa0 AS runtime
WORKDIR /app
# Owned by the user the app runs as. Without the --chown the mode travels
# from the build context: a developer whose umask is 007 checks
# appsettings.json out as rw-rw----, dotnet publish carries that through, and
# the image starts as APP_UID against a file it cannot read. The container
# exits and the e2e suite reports the app as down. A CI runner checks out
# world-readable and never sees it. Ownership rather than a chmod: the image
# should not care what umask built it.
COPY --from=server-build --chown=$APP_UID:$APP_UID /out ./
COPY --from=client-build --chown=$APP_UID:$APP_UID /build/client/dist ./wwwroot
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
