.PHONY: run dev ports shell verify test-server test-client e2e clean help load
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

# Published ports do too, by way of .env — compose only reads numbers, so they
# cannot come from the directory the way the image name does. Two worktrees of
# one repository otherwise fight over 8080, and the copy that loses is the one
# whose owner then browses the other's build believing it to be theirs.
# Generated at parse time so the include has something to read; an existing
# .env is left alone, so `APP_PORT=9001 make run` and a hand-edited file both
# still work.
$(shell ./scripts/worktree-env.sh)
-include .env
APP_PORT    ?= 8080
CLIENT_PORT ?= 5173
export APP_PORT
export CLIENT_PORT

help:
	@python3 -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

ports: ## show this copy's host ports and image name
	@printf 'app     http://localhost:%s   (make run)\n' '$(APP_PORT)'
	@printf 'client  http://localhost:%s   (make dev)\n' '$(CLIENT_PORT)'
	@printf 'image   %s\n' '$(IMAGE)'

run: ## run the production image (client + API in one container); `make ports` says where
	@printf 'this copy serves on http://localhost:%s\n' '$(APP_PORT)'
	docker compose up --build app

dev: ## hot-reloading development servers; `make ports` says where
	@printf 'this copy serves client on :%s, API on :%s\n' '$(CLIENT_PORT)' '$(APP_PORT)'
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
