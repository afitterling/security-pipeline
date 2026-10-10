SHELL := /bin/bash
TF_DIR := infra/terraform
REGION ?= eu-central-1
CLUSTER ?= $(shell cd $(TF_DIR) && terraform output -raw cluster_name 2>/dev/null)

.PHONY: help init plan apply destroy kubeconfig outputs ui-argocd ui-argo ui-dtrack argocd-password add-projects run release status start stop lint local-up local-down local-secrets

local-up: ## run everything on a local kind cluster (free). Needs docker, kind, kubectl, helm
	local/up.sh

local-secrets: ## re-copy ~/.aws, GIT_TOKEN, DTRACK_API_KEY into the local cluster
	local/up.sh --refresh-secrets

local-down: ## delete the local kind cluster
	local/down.sh


help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

init: ## terraform init (needs infra/terraform/backend.hcl)
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

plan: ## terraform plan
	cd $(TF_DIR) && terraform plan

apply: ## terraform apply (interactive confirm)
	cd $(TF_DIR) && terraform apply

destroy: ## terraform destroy (interactive confirm) — deletes cluster and scan history
	cd $(TF_DIR) && terraform destroy

outputs: ## show terraform outputs
	cd $(TF_DIR) && terraform output

kubeconfig: ## write kubeconfig for the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

argocd-password: ## print the initial Argo CD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

ui-argocd: ## port-forward Argo CD -> http://localhost:8443
	scripts/ui.sh argocd

ui-argo: ## port-forward Argo Workflows -> http://localhost:2746
	scripts/ui.sh argo

ui-dtrack: ## port-forward Dependency-Track -> http://localhost:8080 (API :8081)
	scripts/ui.sh dtrack

add-projects: ## usage: make add-projects URLS="https://... https://..."
	scripts/add-projects.sh $(URLS)

run: ## trigger scans: make run NAMES="a b" or make run NAMES=--all
	scripts/run-scans.sh $(NAMES)

start: ## local: start VM + kind node, wait for pods, keep all UI port-forwards running (8443/2746/8080/8081)
	scripts/start.sh

stop: ## local: stop the UI port-forwards started by make start (cluster keeps running)
	scripts/start.sh stop

release: ## App Store/TestFlight release of a gate-passed commit: make release NAME=app [DRY=1]
	scripts/release.sh $(NAME) $(if $(DRY),--dry-run)

status: ## workflows + Dependency-Track summary
	scripts/status.sh

lint: ## helm lint both charts, terraform fmt/validate
	helm lint charts/security-scans -f projects.yaml
	helm lint argocd/bootstrap
	cd $(TF_DIR) && terraform fmt -check -recursive && terraform validate
