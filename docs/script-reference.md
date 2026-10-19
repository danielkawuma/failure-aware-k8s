# Experiment Script Reference

This document inventories the research experiment utilities.

The scripts preserve scenario-specific execution and safety checks.

## Campaign execution

- `scripts/run-campaign.sh`
- `scripts/run-openmrs-all-campaigns.sh`
- `scripts/run-openmrs-campaign.sh`
- `scripts/run-openmrs-cd-campaign.sh`
- `scripts/run-openmrs-e-campaign.sh`
- `scripts/run-overhead-campaign.sh`
- `scripts/run-scenario-d-campaign.sh`
- `scripts/run-scenario-e-campaign.sh`
- `scripts/scenario-a-campaign.sh`

## Experiment execution

- `scripts/run-experiment.sh`
- `scripts/run-openmrs-cd-live-pilot.sh`
- `scripts/run-openmrs-cd-pilot.sh`
- `scripts/run-openmrs-experiment.sh`
- `scripts/run-openmrs-integrated.sh`
- `scripts/run-openmrs-overnight.sh`
- `scripts/run-scenario-d-mariadb.sh`
- `scripts/run-scenario-d.sh`
- `scripts/run-scenario-e.sh`
- `scripts/scenario-a-run.sh`
- `scripts/scenario-a-single-node.sh`

## Faults and fencing

- `scripts/fault.sh`
- `scripts/fence-remote-db.sh`
- `scripts/openmrs-c-fault.sh`
- `scripts/openmrs-cd-fence-original.sh`
- `scripts/openmrs-mariadb-fence.sh`
- `scripts/openmrs-mariadb-unfence-check.sh`
- `scripts/storage-fence.sh`

## OpenMRS preparation and verification

- `scripts/check-openmrs-e.sh`
- `scripts/openmrs-backend-reset.sh`
- `scripts/openmrs-cd-auto-reconcile.sh`
- `scripts/openmrs-cd-check.sh`
- `scripts/openmrs-cd-placement-prepare.sh`
- `scripts/openmrs-cd-prepare.py`
- `scripts/openmrs-cd-reconcile-check.sh`
- `scripts/openmrs-cd-reset-placement.sh`
- `scripts/openmrs-cd-sql-verify.sh`
- `scripts/openmrs-mode-prepare.sh`
- `scripts/openmrs-placement-prepare.sh`

## Measurement and diagnostics

- `scripts/collect-overhead.sh`
- `scripts/openmrs-cd-runtime-diagnostics.sh`
- `scripts/openmrs-db-probe.py`
- `scripts/openmrs-db-tcp-probe.sh`
- `scripts/openmrs-recovery-probe.py`
- `scripts/scenario-a-http-probe.py`

## Candidate selection

- `scripts/candidate-selection/common.sh`
- `scripts/candidate-selection/run-campaign.sh`
- `scripts/candidate-selection/run-suite.sh`
- `scripts/candidate-selection/run-test.sh`
- `scripts/candidate-selection/summarize.sh`

## Remote operations

- `scripts/remote/database-authority-agent.sh`
- `scripts/remote/failure-aware-fault.sh`
- `scripts/remote/fence-mariadb.sh`
- `scripts/remote/fence-postgresql.sh`
- `scripts/remote/openmrs-fault.sh`
- `scripts/remote/storage-fence-worker1.sh`

## Other utilities

- `scripts/experiment-config.sh`
- `scripts/openmrs/seed-clinical-data.py`
- `scripts/openmrs/seed-patients.py`
- `scripts/openmrs-cd-data-access-test.sh`
- `scripts/prepare-scenario-d-run004.sh`
- `scripts/reconcile-scenario-d-mariadb.sh`
- `scripts/scenario-d-config.sh`
