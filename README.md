# OpenMRS resumable B/C/E campaigns

This update replaces only scripts/run-openmrs-all-campaigns.sh and scripts/run-openmrs-e-campaign.sh. It preserves existing mode preparation, backend reset, randomized order, fault checks, and specialized C+D delegation.

For B/C/E: a run directory with COMPLETE and without INCOMPLETE is skipped; a missing directory is executed; any other existing directory aborts without deleting evidence. Each new campaign writes its own plan.csv, summary.csv and campaign.log. SKIPPED_COMPLETE means the previous runner recorded operational completion, not independently verified statistical validity.

C+D is delegated to scripts/run-openmrs-cd-campaign.sh, whose resume and reset behavior is not modified or guaranteed by this update.

Installation: back up the two scripts, extract at repository root, chmod +x, bash -n both scripts. Start with OPENMRS_CAMPAIGN_EXECUTE=false to inspect the plan. A run marked COMPLETE must still be checked for valid evidence before analysis.
