# Experiment Script Reference

This document identifies the experiment execution,
measurement and verification utilities.

## Reproduction

`make reproduce` regenerates results from recorded evidence.

Live experiment campaigns require separate authorization.

## candidate-selection

- `scripts/candidate-selection/common.sh`
- `scripts/candidate-selection/run-campaign.sh`
- `scripts/candidate-selection/run-suite.sh`
- `scripts/candidate-selection/run-test.sh`
- `scripts/candidate-selection/summarize.sh`

## openmrs

- `scripts/openmrs/seed-clinical-data.py`
- `scripts/openmrs/seed-patients.py`

## openmrs/backend

- `scripts/openmrs/backend/openmrs-backend-reset.sh`
- `scripts/openmrs/backend/openmrs-c-fault.sh`
- `scripts/openmrs/backend/openmrs-mode-prepare.sh`
- `scripts/openmrs/backend/openmrs-placement-prepare.sh`
- `scripts/openmrs/backend/run-openmrs-experiment.sh`
- `scripts/openmrs/backend/run-openmrs-integrated.sh`

## openmrs/campaigns

- `scripts/openmrs/campaigns/run-openmrs-all-campaigns.sh`
- `scripts/openmrs/campaigns/run-openmrs-campaign.sh`
- `scripts/openmrs/campaigns/run-openmrs-cd-campaign.sh`
- `scripts/openmrs/campaigns/run-openmrs-cd-live-pilot.sh`
- `scripts/openmrs/campaigns/run-openmrs-cd-pilot.sh`
- `scripts/openmrs/campaigns/run-openmrs-e-campaign.sh`
- `scripts/openmrs/campaigns/run-openmrs-overnight.sh`

## openmrs/database

- `scripts/openmrs/database/openmrs-cd-auto-reconcile.sh`
- `scripts/openmrs/database/openmrs-cd-placement-prepare.sh`
- `scripts/openmrs/database/openmrs-cd-prepare.py`
- `scripts/openmrs/database/openmrs-cd-reset-placement.sh`

## openmrs/diagnostics

- `scripts/openmrs/diagnostics/check-openmrs-e.sh`
- `scripts/openmrs/diagnostics/openmrs-cd-check.sh`
- `scripts/openmrs/diagnostics/openmrs-cd-data-access-test.sh`
- `scripts/openmrs/diagnostics/openmrs-cd-reconcile-check.sh`
- `scripts/openmrs/diagnostics/openmrs-cd-runtime-diagnostics.sh`
- `scripts/openmrs/diagnostics/openmrs-cd-sql-verify.sh`
- `scripts/openmrs/diagnostics/openmrs-db-probe.py`
- `scripts/openmrs/diagnostics/openmrs-db-tcp-probe.sh`
- `scripts/openmrs/diagnostics/openmrs-recovery-probe.py`

## openmrs/fencing

- `scripts/openmrs/fencing/openmrs-cd-fence-original.sh`
- `scripts/openmrs/fencing/openmrs-mariadb-fence.sh`
- `scripts/openmrs/fencing/openmrs-mariadb-unfence-check.sh`

## overhead

- `scripts/overhead/collect-overhead.sh`
- `scripts/overhead/run-overhead-campaign.sh`

## remote

- `scripts/remote/database-authority-agent.sh`
- `scripts/remote/failure-aware-fault.sh`
- `scripts/remote/fence-mariadb.sh`
- `scripts/remote/fence-postgresql.sh`
- `scripts/remote/openmrs-fault.sh`
- `scripts/remote/storage-fence-worker1.sh`

## scenario-a

- `scripts/scenario-a/scenario-a-campaign.sh`
- `scripts/scenario-a/scenario-a-http-probe.py`
- `scripts/scenario-a/scenario-a-run.sh`
- `scripts/scenario-a/scenario-a-single-node.sh`

## scenario-d

- `scripts/scenario-d/prepare-scenario-d-run004.sh`
- `scripts/scenario-d/reconcile-scenario-d-mariadb.sh`
- `scripts/scenario-d/run-scenario-d-campaign.sh`
- `scripts/scenario-d/run-scenario-d-mariadb.sh`
- `scripts/scenario-d/run-scenario-d.sh`
- `scripts/scenario-d/scenario-d-config.sh`

## scenario-e

- `scripts/scenario-e/run-scenario-e-campaign.sh`
- `scripts/scenario-e/run-scenario-e.sh`

## shared

- `scripts/experiment-config.sh`
- `scripts/fault.sh`
- `scripts/fence-remote-db.sh`
- `scripts/openmrs-backend-reset.sh`
- `scripts/openmrs-c-fault.sh`
- `scripts/openmrs-cd-check.sh`
- `scripts/openmrs-cd-data-access-test.sh`
- `scripts/openmrs-cd-fence-original.sh`
- `scripts/openmrs-cd-placement-prepare.sh`
- `scripts/openmrs-cd-reconcile-check.sh`
- `scripts/openmrs-cd-reset-placement.sh`
- `scripts/openmrs-cd-runtime-diagnostics.sh`
- `scripts/openmrs-cd-sql-verify.sh`
- `scripts/openmrs-db-tcp-probe.sh`
- `scripts/openmrs-mariadb-fence.sh`
- `scripts/openmrs-mariadb-unfence-check.sh`
- `scripts/run-campaign.sh`
- `scripts/run-experiment.sh`
- `scripts/scenario-d-config.sh`
- `scripts/storage-fence.sh`
