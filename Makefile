.PHONY: run dev shell load verify test-server test-client e2e clean help
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
	docker compose up -d --build app
	docker compose --profile load run --rm k6
	docker compose down

verify: ## run the full verification suite with a pass/fail tally
	./scripts/verify.sh

test-server: ## run the server unit tests
	docker run --rm -v $(CURDIR):/src:ro -v $(IMAGE)-nuget:/root/.nuget mcr.microsoft.com/dotnet/sdk:10.0 \
		bash -c 'cp -r /src /w && cd /w/server && dotnet test Api.Tests'

# Derived from the Dockerfile like verify.sh does, so the Makefile cannot
# drift to a different node major than the image the code actually ships on.
NODE_IMAGE = $(shell sed -n 's/^FROM \(node:[^@ ]*\).*/\1/p' Dockerfile | head -1)

test-client: ## run the client typecheck, lint and unit tests
	docker run --rm -v $(CURDIR):/src:ro -v $(IMAGE)-npm:/npm-cache -e npm_config_cache=/npm-cache $(NODE_IMAGE) \
		sh -c 'cp -r /src/client /w && cd /w && npm ci --no-audit --no-fund && npm run typecheck && npm run lint && npm run test'

e2e: ## run only the end-to-end suite (part of `make verify`)
	./scripts/verify.sh || true

clean: ## remove compose containers and the verification network
	docker compose --profile dev down --remove-orphans
	docker network rm $(IMAGE)-verify-net 2>/dev/null || true
