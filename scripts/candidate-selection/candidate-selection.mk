# Optional Makefile fragment for the multi-candidate validation.
# Either include this file from the root Makefile or copy the targets.

.PHONY: candidate-selection candidate-selection-campaign candidate-selection-summary

candidate-selection:
	./scripts/candidate-selection/run-campaign.sh 1

candidate-selection-campaign:
	./scripts/candidate-selection/run-campaign.sh $${RUNS:-5}

candidate-selection-summary:
	@test -n "$(CAMPAIGN_DIR)" || (echo "Set CAMPAIGN_DIR=results/candidate-selection/campaign-..." && exit 1)
	./scripts/candidate-selection/summarize.sh "$(CAMPAIGN_DIR)"
