SHELL         := /bin/bash
COMPOSE       := docker compose
ENV_FILE      := .env
PROJECT_NAME  := infra

COMPOSE_FILES := \
	-f compose/core.yaml \
	-f compose/overleaf.yaml

COMPOSE_CMD   := $(COMPOSE) --env-file $(ENV_FILE) $(COMPOSE_FILES) -p $(PROJECT_NAME)

up: ## Start all services
	$(COMPOSE_CMD) up -d

down: ## Stop all services
	$(COMPOSE_CMD) down

restart: ## Restart all services
	$(COMPOSE_CMD) restart

logs: ## Tail logs (all services)
	$(COMPOSE_CMD) logs -f --tail=100

ps: ## Show running containers
	$(COMPOSE_CMD) ps

pull: ## Pull latest images for all services
	$(COMPOSE_CMD) pull


logs-%: ## Tail logs for a specific service (e.g., make logs-overleaf)
	$(COMPOSE_CMD) logs -f --tail=100 $*

bootstrap: ## Initial server setup (run once)
	@sudo bash scripts/bootstrap.sh

update: ## Pull latest images and recreate changed containers
	$(COMPOSE_CMD) pull
	$(COMPOSE_CMD) up -d --remove-orphans

prune: ## Clean up unused Docker resources
	docker system prune -af --volumes && make net

purge: ## "fresh restart" | This script should not be run
	@bash scripts/purge.sh

net: ## Create required docker network
	docker network create --subnet=172.20.0.0/24 net 2>/dev/null || echo "Network 'net' already exists."
