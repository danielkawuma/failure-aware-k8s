SHELL := /bin/bash

REPO_ROOT := $(shell pwd)

HARNESS_DIR := $(REPO_ROOT)/harness
CONTROLLER_DIR := $(REPO_ROOT)/controller

SCRIPTS_DIR := $(REPO_ROOT)/scripts
ANALYSIS_DIR := $(REPO_ROOT)/analysis

.PHONY: \
	build \
	build-harness \
	build-controller \
	validate \
	validate-ssh \
	validate-k8s \
	validate-binaries \
	scenario-c-native \
	scenario-c-failure-aware \
	scenario-b-native \
	scenario-b-failure-aware \
	campaign-scenario-c \
	campaign-scenario-b \
	campaign \
	analyze \
	reproduce \
	clean-evaluation

build: build-harness build-controller

build-harness:
	@echo "Building Rust harness..."
	cd $(HARNESS_DIR) && cargo build

build-controller:
	@echo "Building Failure-Aware Controller..."
	cd $(CONTROLLER_DIR) && cargo build

validate: validate-ssh validate-k8s validate-binaries
	@echo
	@echo "Reproducibility validation complete."

validate-ssh:
	@echo "Validating SSH and passwordless sudo..."
	ssh \
		-i /home/daniel/.ssh/k8s-aware \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		ubuntu@102.34.160.87 \
		'sudo -n true && echo "SSH and passwordless sudo: OK"'

validate-k8s:
	@echo "Validating Kubernetes access..."
	kubectl get nodes
	@echo
	kubectl get deployment baseline-web \
		-n failure-aware
	@echo
	kubectl get service baseline-web \
		-n failure-aware

validate-binaries:
	@echo "Validating compiled binaries..."

	test -x \
		$(HARNESS_DIR)/target/debug/failure-aware-harness

	test -x \
		$(CONTROLLER_DIR)/target/debug/failure-aware-controller

	@echo "Compiled binaries: OK"

scenario-c-native:
	$(SCRIPTS_DIR)/run-campaign.sh \
		scenario-c \
		native \
		30

scenario-c-failure-aware:
	$(SCRIPTS_DIR)/run-campaign.sh \
		scenario-c \
		failure-aware \
		30

scenario-b-native:
	$(SCRIPTS_DIR)/run-campaign.sh \
		scenario-b \
		native \
		30

scenario-b-failure-aware:
	$(SCRIPTS_DIR)/run-campaign.sh \
		scenario-b \
		failure-aware \
		30

campaign-scenario-c:
	$(MAKE) scenario-c-native
	$(MAKE) scenario-c-failure-aware

campaign-scenario-b:
	$(MAKE) scenario-b-native
	$(MAKE) scenario-b-failure-aware

campaign:
	$(MAKE) campaign-scenario-c
	$(MAKE) campaign-scenario-b

analyze:
	@echo "Running analysis pipeline..."

	@if [ ! -f "$(ANALYSIS_DIR)/extract_metrics.py" ]; then \
		echo "Missing analysis/extract_metrics.py"; \
		exit 1; \
	fi

	@if [ ! -f "$(ANALYSIS_DIR)/summarize_results.py" ]; then \
		echo "Missing analysis/summarize_results.py"; \
		exit 1; \
	fi

	python3 \
		$(ANALYSIS_DIR)/extract_metrics.py

	python3 \
		$(ANALYSIS_DIR)/summarize_results.py

reproduce:
	$(MAKE) build
	$(MAKE) validate
	$(MAKE) campaign
	$(MAKE) analyze

clean-evaluation:
	@echo "WARNING: this removes formal evaluation runs."
	@read -p "Continue? [y/N] " answer; \
	if [[ "$$answer" == "y" || "$$answer" == "Y" ]]; then \
		rm -rf \
			$(REPO_ROOT)/experiments/evaluation/scenario-b/native/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-b/failure-aware/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-c/native/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-c/failure-aware/run-*; \
	else \
		echo "Cancelled."; \
	fi