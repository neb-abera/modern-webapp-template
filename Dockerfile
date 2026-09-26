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
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:35d40304542c8689331f8cab17c65926cdf48fe711e289321d71924b230a7d29 AS server-build
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
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:35d40304542c8689331f8cab17c65926cdf48fe711e289321d71924b230a7d29 AS dev
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
FROM jdkato/vale:v3.22.0@sha256:0ef74c2c8331a2cc8739ecc8b4f7cc6672e61524c3697e8c8857bc86b724a28e AS vale

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
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled@sha256:9651fa59abcdf177c30392cb44a820605ca5d618429ab37acbf6e7c644510b02 AS runtime
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
