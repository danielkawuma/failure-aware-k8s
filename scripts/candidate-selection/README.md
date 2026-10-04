# Reproducible multi-candidate recovery-selection campaign

This bundle automates the four controlled validation experiments used for
the multi-candidate extension of the Failure-Aware Kubernetes controller:

1. Reliability selection
   - Worker2, Worker3 and Worker4 are all eligible.
   - Expected selection: Worker3.
   - Scenario B is used, therefore the final decision must be PRESERVE.

2. Resource exclusion
   - A controlled Pod requests 1950m CPU on Worker3.
   - Worker3 has 2000m allocatable CPU, leaving 50m, below the protected
     workload's 100m requirement.
   - Expected selection: Worker4.
   - Final decision: PRESERVE.

3. Availability exclusion
   - Worker3 is cordoned while remaining Ready.
   - Expected selection: Worker4.
   - Final decision: PRESERVE.

4. RECOVER placement
   - Scenario C makes the original workload unreachable.
   - Expected selection: Worker3.
   - Expected decision: RECOVER.
   - The script verifies the Deployment hostname constraint and confirms
     that the replacement Pod actually becomes Running on Worker3.

## Repository placement

Copy these files into the existing repository:

    scripts/candidate-selection/common.sh
    scripts/candidate-selection/run-test.sh
    scripts/candidate-selection/run-suite.sh
    scripts/candidate-selection/run-campaign.sh
    scripts/candidate-selection/summarize.sh
    workloads/candidate-selection/worker3-resource-pressure.yaml

Then:

    chmod +x scripts/candidate-selection/*.sh

## Preconditions

The scripts assume the existing repository already contains:

    controller/target/debug/failure-aware-controller
    controller/config/controller.json
    controller/config/node-history.json
    scripts/fault.sh
    deployment/failure-aware baseline-web workload in namespace failure-aware

They also assume:

    k3s-worker1 = fault target
    k3s-worker2 = recovery candidate
    k3s-worker3 = recovery candidate
    k3s-worker4 = recovery candidate

and each candidate has:

    failure-aware.io/role=recovery-candidate

The campaign intentionally refuses to start if another
failure-aware-controller process is already running.

## One complete reproducibility run

From the repository root:

    ./scripts/candidate-selection/run-campaign.sh 1

Results are stored under:

    results/candidate-selection/campaign-<UTC timestamp>/run-001/

Every test contains:

    pre-test.txt
    controller.log
    fault-apply.log
    post-condition.txt
    result.env
    COMPLETE

The recover test additionally records:

    original_pod.txt
    original_pod_ip.txt
    replacement_pod.txt
    replacement_node.txt
    enforced_hostname_selector.txt

The campaign itself receives a COMPLETE marker only after all four tests
pass their assertions.

## Repeated campaign

To repeat the complete four-test suite five times:

    ./scripts/candidate-selection/run-campaign.sh 5

This is useful if you want repeated validation, but the current report
treats the four multi-candidate experiments as controlled mechanism
validation rather than a timing distribution. Do not silently merge
additional repetitions into the existing reported dataset; update the
reported sample sizes if you decide to use the new runs academically.

## Summarize a campaign

    ./scripts/candidate-selection/summarize.sh \
      results/candidate-selection/campaign-<UTC timestamp>

## Safety and cleanup

Before every test the automation:

- clears stale fault rules;
- deletes the resource-pressure Pod if present;
- uncordons all recovery candidates;
- waits for Worker1 to be Ready;
- pins the baseline Deployment back to Worker1;
- waits for the baseline workload to be Running on Worker1.

After every test it performs the same restoration sequence.

The RECOVER test temporarily allows the controller to change the
baseline Deployment nodeSelector to Worker3. Cleanup restores the
baseline Deployment to Worker1 before the next test and before the
campaign exits.

## Controlled reliability inputs

The scripts do not rewrite controller/config/node-history.json.
They deliberately use the controlled reliability inputs already present
in the repository. This preserves the experiment described in the report.
