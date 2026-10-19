# Experiment Script Reference

Experiment execution and verification utilities.

## Reproduction

`make reproduce` regenerates results from recorded evidence.

## candidate-selection

- `/home/daniel/failure-aware-k8s/scripts/candidate-selection/common.sh`
- `/home/daniel/failure-aware-k8s/scripts/candidate-selection/run-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/candidate-selection/run-suite.sh`
- `/home/daniel/failure-aware-k8s/scripts/candidate-selection/run-test.sh`
- `/home/daniel/failure-aware-k8s/scripts/candidate-selection/summarize.sh`

## openmrs

- `/home/daniel/failure-aware-k8s/scripts/openmrs/seed-clinical-data.py`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/seed-patients.py`

## openmrs/backend

- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/openmrs-backend-reset.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/openmrs-c-fault.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/openmrs-mode-prepare.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/openmrs-placement-prepare.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/run-openmrs-experiment.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/backend/run-openmrs-integrated.sh`

## openmrs/campaigns

- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-all-campaigns.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-cd-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-cd-live-pilot.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-cd-pilot.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-e-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/campaigns/run-openmrs-overnight.sh`

## openmrs/database

- `/home/daniel/failure-aware-k8s/scripts/openmrs/database/openmrs-cd-auto-reconcile.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/database/openmrs-cd-placement-prepare.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/database/openmrs-cd-prepare.py`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/database/openmrs-cd-reset-placement.sh`

## openmrs/diagnostics

- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/check-openmrs-e.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-cd-check.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-cd-data-access-test.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-cd-reconcile-check.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-cd-runtime-diagnostics.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-cd-sql-verify.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-db-probe.py`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-db-tcp-probe.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/diagnostics/openmrs-recovery-probe.py`

## openmrs/fencing

- `/home/daniel/failure-aware-k8s/scripts/openmrs/fencing/openmrs-cd-fence-original.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/fencing/openmrs-mariadb-fence.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs/fencing/openmrs-mariadb-unfence-check.sh`

## overhead

- `/home/daniel/failure-aware-k8s/scripts/overhead/collect-overhead.sh`
- `/home/daniel/failure-aware-k8s/scripts/overhead/run-overhead-campaign.sh`

## remote

- `/home/daniel/failure-aware-k8s/scripts/remote/database-authority-agent.sh`
- `/home/daniel/failure-aware-k8s/scripts/remote/failure-aware-fault.sh`
- `/home/daniel/failure-aware-k8s/scripts/remote/fence-mariadb.sh`
- `/home/daniel/failure-aware-k8s/scripts/remote/fence-postgresql.sh`
- `/home/daniel/failure-aware-k8s/scripts/remote/openmrs-fault.sh`
- `/home/daniel/failure-aware-k8s/scripts/remote/storage-fence-worker1.sh`

## scenario-a

- `/home/daniel/failure-aware-k8s/scripts/scenario-a/scenario-a-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-a/scenario-a-http-probe.py`
- `/home/daniel/failure-aware-k8s/scripts/scenario-a/scenario-a-run.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-a/scenario-a-single-node.sh`

## scenario-d

- `/home/daniel/failure-aware-k8s/scripts/scenario-d/prepare-scenario-d-run004.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d/reconcile-scenario-d-mariadb.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d/run-scenario-d-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d/run-scenario-d-mariadb.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d/run-scenario-d.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d/scenario-d-config.sh`

## scenario-e

- `/home/daniel/failure-aware-k8s/scripts/scenario-e/run-scenario-e-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-e/run-scenario-e.sh`

## shared

- `/home/daniel/failure-aware-k8s/scripts/experiment-config.sh`
- `/home/daniel/failure-aware-k8s/scripts/fault.sh`
- `/home/daniel/failure-aware-k8s/scripts/fence-remote-db.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs-cd-fence-original.sh`
- `/home/daniel/failure-aware-k8s/scripts/openmrs-mariadb-fence.sh`
- `/home/daniel/failure-aware-k8s/scripts/run-campaign.sh`
- `/home/daniel/failure-aware-k8s/scripts/run-experiment.sh`
- `/home/daniel/failure-aware-k8s/scripts/scenario-d-config.sh`
- `/home/daniel/failure-aware-k8s/scripts/storage-fence.sh`
