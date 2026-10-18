SHELL := /bin/bash

REPO_ROOT := $(shell pwd)
HARNESS_DIR := $(REPO_ROOT)/harness
CONTROLLER_DIR := $(REPO_ROOT)/controller
SCRIPTS_DIR := $(REPO_ROOT)/scripts
ANALYSIS_DIR := $(REPO_ROOT)/analysis

SCENARIO_B_RUNS ?= 30
SCENARIO_C_RUNS ?= 30
SCENARIO_D_START_RUN ?= 201
SCENARIO_D_RUNS ?= 30
SCENARIO_E_RUNS_PER_PROFILE ?= 10
SCENARIO_E_START_RUN ?= 1
CANDIDATE_SELECTION_RUNS ?= 1

.PHONY: \
	build \
	build-harness \
	build-controller \
	validate \
	validate-ssh \
	validate-k8s \
	validate-binaries \
	scenario-b-native \
	scenario-b-failure-aware \
	scenario-c-native \
	scenario-c-failure-aware \
	scenario-d-failure-aware \
	scenario-e-failure-aware \
	candidate-selection \
	campaign-scenario-b \
	campaign-scenario-c \
	campaign-scenario-d \
	campaign-scenario-e \
	campaign-candidate-selection \
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
	@test -n "$$SSH_KEY" || \
		(echo "ERROR: SSH_KEY is not set."; \
		 echo 'Set it using: export SSH_KEY="$$HOME/.ssh/<your-private-key>"'; \
		 exit 1)
	@test -f "$$SSH_KEY" || \
		(echo "ERROR: SSH key not found: $$SSH_KEY"; exit 1)
	ssh \
		-i "$$SSH_KEY" \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		ubuntu@102.34.160.87 \
		'sudo -n true && echo "SSH and passwordless sudo: OK"'

validate-k8s:
	@echo "Validating Kubernetes access..."
	kubectl get nodes
	@echo
	kubectl get deployment baseline-web -n failure-aware
	@echo
	kubectl get service baseline-web -n failure-aware

validate-binaries:
	@echo "Validating compiled binaries..."
	@test -x $(HARNESS_DIR)/target/debug/failure-aware-harness
	@test -x $(CONTROLLER_DIR)/target/debug/failure-aware-controller
	@echo "Compiled binaries: OK"

scenario-b-native:
	$(SCRIPTS_DIR)/run-campaign.sh scenario-b native $(SCENARIO_B_RUNS)

scenario-b-failure-aware:
	$(SCRIPTS_DIR)/run-campaign.sh scenario-b failure-aware $(SCENARIO_B_RUNS)

scenario-c-native:
	$(SCRIPTS_DIR)/run-campaign.sh scenario-c native $(SCENARIO_C_RUNS)

scenario-c-failure-aware:
	$(SCRIPTS_DIR)/run-campaign.sh scenario-c failure-aware $(SCENARIO_C_RUNS)

scenario-d-failure-aware:
	$(SCRIPTS_DIR)/run-scenario-d-campaign.sh \
		$(SCENARIO_D_START_RUN) \
		$(SCENARIO_D_RUNS)

scenario-e-failure-aware:
	$(SCRIPTS_DIR)/run-scenario-e-campaign.sh \
		$(SCENARIO_E_RUNS_PER_PROFILE) \
		$(SCENARIO_E_START_RUN)

candidate-selection:
	$(SCRIPTS_DIR)/candidate-selection/run-campaign.sh \
		$(CANDIDATE_SELECTION_RUNS)

campaign-scenario-b:
	$(MAKE) scenario-b-native
	$(MAKE) scenario-b-failure-aware

campaign-scenario-c:
	$(MAKE) scenario-c-native
	$(MAKE) scenario-c-failure-aware

campaign-scenario-d:
	$(MAKE) scenario-d-failure-aware

campaign-scenario-e:
	$(MAKE) scenario-e-failure-aware

campaign-candidate-selection:
	$(MAKE) candidate-selection

campaign:
	$(MAKE) campaign-scenario-b
	$(MAKE) campaign-scenario-c
	$(MAKE) campaign-scenario-d
	$(MAKE) campaign-scenario-e
	$(MAKE) campaign-candidate-selection

analyze:
	@echo "Running analysis pipeline..."
	@test -f "$(ANALYSIS_DIR)/extract_metrics.py" || \
		(echo "Missing analysis/extract_metrics.py"; exit 1)
	@test -f "$(ANALYSIS_DIR)/summarize_results.py" || \
		(echo "Missing analysis/summarize_results.py"; exit 1)
	python3 $(ANALYSIS_DIR)/extract_metrics.py
	python3 $(ANALYSIS_DIR)/summarize_results.py

reproduce:
	$(MAKE) build
	$(MAKE) validate
	$(MAKE) campaign
	$(MAKE) analyze

clean-evaluation:
	@echo "WARNING: this removes formal evaluation runs for Scenarios B, C and E."
	@echo "Scenario D and candidate-selection results are intentionally not removed."
	@read -p "Continue? [y/N] " answer; \
	if [[ "$$answer" == "y" || "$$answer" == "Y" ]]; then \
		rm -rf \
			$(REPO_ROOT)/experiments/evaluation/scenario-b/native/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-b/failure-aware/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-c/native/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-c/failure-aware/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-e/failure-aware/mild/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-e/failure-aware/moderate/run-* \
			$(REPO_ROOT)/experiments/evaluation/scenario-e/failure-aware/severe/run-*; \
	else \
		echo "Cancelled."; \
	fi
