# Axis + ForgeFX sandboxed stack.
# Uses podman-compose if present, otherwise `podman compose` (keep-groups needs Podman).
# Override the compose command with:  make up COMPOSE="podman compose"

COMPOSE ?= $(shell command -v podman-compose >/dev/null 2>&1 && echo podman-compose || echo "podman compose")
URL     := http://127.0.0.1:5056
VOLUME  := axis_axis-data
IMAGE   := axis-stack:local

.DEFAULT_GOAL := help

.PHONY: help up build start stop down logs verify open reset compose-cmd update update-stable

help: ## Show this help
	@echo "Axis + ForgeFX - sandboxed Podman stack"
	@echo
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Using compose command: $(COMPOSE)"

compose-cmd: ## Print the detected compose command
	@echo "$(COMPOSE)"

up: ## Build (if needed) and run in the foreground
	$(COMPOSE) up --build

start: ## Build (if needed) and run detached (background)
	$(COMPOSE) up --build -d
	@echo "Started. Open $(URL)  (run 'make verify' to check device detection)"

build: ## Build the image only
	$(COMPOSE) build

update: ## Pin latest upstream tags (MIDI/ForgeFX/Axis) into the Dockerfile (then 'make build')
	./update-refs.sh

update-stable: ## Same as 'update' but ignore pre-release (-beta) tags
	./update-refs.sh --stable

stop: ## Stop the running container (keeps it)
	$(COMPOSE) stop

down: ## Stop and remove the container + network
	$(COMPOSE) down

logs: ## Follow container logs
	$(COMPOSE) logs -f

verify: ## Check the server sees the Axe-Fx III (ports + diagnostics)
	@echo "== /ports (look for 'Axe-Fx III MIDI In/Out') =="
	@curl -fsS $(URL)/ports || echo "  (server not reachable - is it up? try 'make start')"
	@echo
	@echo "== /diag (MIDI availability + resolved connection) =="
	@curl -fsS $(URL)/diag  || echo "  (server not reachable)"
	@echo

open: ## Open the UI in your default browser
	@xdg-open $(URL) >/dev/null 2>&1 || echo "Open $(URL) in your browser"

reset: ## Stop, then wipe the data volume AND the built image (destructive)
	-$(COMPOSE) down
	-podman volume rm $(VOLUME)
	-podman rmi $(IMAGE)
	@echo "Reset complete (presets/backups/config wiped, image removed)."
