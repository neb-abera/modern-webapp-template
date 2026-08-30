.PHONY: run dev shell verify test-server test-client e2e clean help load
.DEFAULT_GOAL := help

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-20s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

# Docker image/container names derive from the checkout directory, so
# projects generated from this template need no edits here.
IMAGE := $(shell basename "$(CURDIR)" | tr '[:upper:]' '[:lower:]')

help:
	@python3 -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

run: ## run the production image (client + API in one container) on :8080
	docker compose up --build app

dev: ## hot-reloading development servers (client :5173, API :8080)
	docker compose --profile dev up --build

shell: ## open a development shell inside the toolchain image
	docker build -t $(IMAGE)-dev:latest --target dev .
	docker rm -f $(IMAGE)-dev 2>/dev/null || true
	docker run --rm -it --name $(IMAGE)-dev -v $(CURDIR):/work -w /work $(IMAGE)-dev:latest bash

load: ## run the k6 load harness against the production-like app
	docker compose up -d --build --wait app
	docker compose --profile load run --rm k6; status=$$?; docker compose down; exit $$status

verify: ## run the full verification suite with a pass/fail tally
	./scripts/verify.sh

# Toolchain images are derived from the Dockerfile and e2e/package.json the
# way verify.sh derives them, so the Makefile cannot drift from the images
# the code actually builds and tests with.
SDK_IMAGE = $(shell sed -n 's|^FROM \(mcr\.microsoft\.com/dotnet/sdk:[^ ]*\) AS server-build$$|\1|p' Dockerfile)
NODE_IMAGE = $(shell sed -n 's/^FROM \(node:[^@ ]*\).*/\1/p' Dockerfile | head -1)
PLAYWRIGHT_IMAGE = mcr.microsoft.com/playwright:v$(shell sed -n 's|.*"@playwright/test": "\([^"]*\)".*|\1|p' e2e/package.json)-noble

test-server: ## run the server unit tests
	docker run --rm -v $(CURDIR):/src:ro -v $(IMAGE)-nuget:/root/.nuget $(SDK_IMAGE) \
		bash -c 'cp -r /src /w && cd /w/server && dotnet test Api.Tests -p:RestoreLockedMode=true'

test-client: ## run the client typecheck, lint and unit tests
	docker run --rm -v $(CURDIR):/src:ro -v $(IMAGE)-npm:/npm-cache -e npm_config_cache=/npm-cache $(NODE_IMAGE) \
		sh -c 'cp -r /src/client /w && cd /w && npm ci --no-audit --no-fund && npm run typecheck && npm run lint && npm run test'

e2e: ## run only the Playwright end-to-end suite against the production image
	docker compose up -d --build --wait app
	docker run --rm --network $(IMAGE)_default -v $(CURDIR)/e2e:/src:ro -v $(IMAGE)-npm:/npm-cache \
		-e npm_config_cache=/npm-cache -e E2E_BASE_URL=http://app-under-test:8080 $(PLAYWRIGHT_IMAGE) \
		bash -c 'cp -r /src /w && cd /w && npm ci --no-audit --no-fund && npx playwright test'; \
	status=$$?; docker compose down; exit $$status

clean: ## remove compose containers and the verification network
	docker compose --profile dev down --remove-orphans
	docker network rm $(IMAGE)-verify-net 2>/dev/null || true
