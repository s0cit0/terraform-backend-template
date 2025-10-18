SHELL := /bin/bash
TF ?= terraform

.PHONY: help fmt fmt-check init validate check clean

.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?#' Makefile | sort | awk 'BEGIN {FS = ":.*?#"} {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

fmt: ## Format all Terraform configuration files in-place
	$(TF) fmt -recursive

fmt-check: ## Check Terraform formatting without modifying files
	$(TF) fmt -recursive -check

init: ## Initialize providers without touching the remote backend
	$(TF) init -backend=false

validate: init ## Validate Terraform configuration
	$(TF) validate

check: fmt-check validate ## Run formatting check and validation

clean: ## Remove Terraform initialization artifacts
	rm -rf .terraform terraform.tfstate terraform.tfstate.backup
