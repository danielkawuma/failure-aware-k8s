# Pre-registered hypotheses for the Midterm Test 2 campaigns

Status: committed before any of the campaigns below were started.
Cite this file by the hash of the commit that adds it. It is not edited
after the first new run starts; any correction goes in a new dated
section at the end, and the manuscript reports both.

Campaign runners: `scripts/ladder/campaign.sh` (H1, H2, H4, H5) and
`scripts/live-writer/campaign.sh` (H3). Analysis: `analysis/analyze-ladder.py`
and `analysis/analyze-live-writer.py`, which apply the rules below without
change.

## Arms

| Arm | Configuration (`workloads/ladder/`) |
|---|---|
| V0 | Native K3s, default 300 s `NoExecute` tolerations (`nginx-v0.yaml`) |
| T10 | Native K3s, `tolerationSeconds: 10` for both taints (`nginx-t10.yaml`) |
| NX | Native K3s, non-expiring `NoExecute` tolerations, controller not running (`nginx-nx.yaml`) |
| R2 | Native K3s, two replicas on different nodes, PodDisruptionBudget `minAvailable: 1`, default tolerations (`nginx-r2.yaml`) |
| FA1 | Non-expiring tolerations with the Failure-Aware controller running (`nginx-fa1.yaml`) |

## Fault conditions

- **Reachable partition (RP):** Worker1's path to the API server is
  blocked (Scenario B rule); the workload stays reachable on Worker1.
  Durations 120 s (longer than the T10 window, shorter than the V0
  window) and 600 s (longer than every finite window). The partition is
  healed at the end of the duration and observed for 60 s.
- **Unreachable workload (UW):** Worker1's API-server path and the
  workload Pod are both blocked (Scenario C rule) for 480 s, then healed
  and observed for 60 s.

## Design

- Five runs per arm and condition: 5 arms × 3 conditions × 5 = 75 runs.
- One seeded random order over all 75 runs, written to
  `ladder-plan.csv` with the seed before the first run.
- Every attempt keeps its directory; an interrupted or failed run is
  marked `ABORTED` and reported, never deleted.
- Recorded each second: the Service through the Worker2 NodePort
  (harness), the Worker1 NodePort directly (the controller's
  verification path), the Service ClusterIP from a client Pod on
  Worker2, EndpointSlice membership and conditions, node readiness,
  Lease renewals, taints, and Pod phase and placement; for FA1, the
  controller's CPU ticks and resident memory.

Five runs per cell is fewer than the 30 the examiner requested; it is
what the remaining time allows, and every interval is reported for the
sample size actually obtained.

## H1: preservation of a reachable workload

At each RP duration, the FA1 original-Pod replacement rate is less than
or equal to the lowest replacement rate among V0, T10 and R2.

- Falsified if FA1 replaces the original Pod in more runs than the best
  of V0, T10 and R2 at either duration.
- Reported with Clopper-Pearson intervals, Fisher exact tests against
  each comparator, and Holm-adjusted p-values.
- NX is expected to retain the Pod as well, so H1 does not separate FA1
  from NX. H2 does.

## H2: recovery of an unreachable workload

Under UW, the FA1 median time from fault to restored service through the
Worker2 NodePort is within 15 s of the T10 median, and NX does not
restore service before the fault is healed in any run.

- Falsified if the FA1 median exceeds the T10 median by more than 15 s,
  or if any NX run restores service before the fault is healed.
- Medians are reported with BCa bootstrap intervals (10,000 resamples)
  and Cliff's delta.
- The claimed advance is the conjunction of H1 and H2: no single native
  arm both retains a reachable workload (H1) and recovers an unreachable
  one within 15 s of T10 (H2).

## H3: no commits by the original writer after the fence

Runner: `scripts/live-writer/campaign.sh`.
Analysis: `analysis/analyze-live-writer.py`.

**Setup.** Each run uses a fresh copy of the baseline MariaDB datadir on
the experimental NFS server (Worker3). A writer container next to the
original MariaDB on Worker1 inserts one row every 0.2 s, each with a
unique, increasing sequence number and a server-side `NOW(6)` commit
time. Worker1 is then cut off from the API server (Scenario B rule),
while its storage path stays open. No SSH to Worker1 is used from the
start of the partition to the end of the fault phase.

**Arms.** Ten runs per arm, in one seeded random order:

- **Fenced:**
  1. At suspicion (`Ready=Unknown`), the NFS server drops Worker1's
     TCP 2049 traffic and the fence is verified.
  2. A replacement MariaDB with its own writer starts on Worker2.
  3. After the partition heals, Worker1 is rebooted to retire the
     original process.
  4. The fence is removed only after no `mariadbd` remains on Worker1.
- **Unfenced:** no fence. At suspicion + 10 s, the point at which a
  10-s toleration would release the Pod, a replacement MariaDB starts
  on Worker2 against the same datadir, as native recovery would do.

**Measurement.** A verifier MariaDB on Worker2 reads every committed row
after the run. The original's commit times are converted to the local
clock with the Worker1 clock offset measured at the start of the run.

**Rules.**

- Fenced arm: zero commits by the original writer after the
  fence-verified time, in every run. Falsified by one such commit in any
  run.
- Unfenced arm: the count of original commits between the replacement's
  release and the end of the partition is reported as observed. If no
  unfenced run shows any such commit, the test cannot discriminate and
  H3 is reported as inconclusive, not as supported.
- Also reported:
  - acknowledged writes missing from the database;
  - runs in which the two writers committed in overlapping intervals;
  - whether the replacement became ready.
- The number of runs with a violation is reported with its
  Clopper-Pearson upper bound. Ten runs per arm cannot bound the
  violation rate below 1 % (0 of 10 gives 30.8 %); the examiner's 300
  runs per arm is a stated limitation.

## H4: probe error rates

Probes use the controller's parameters (3 s total timeout per attempt,
0.5 s between attempts) and its classification rule
(`controller/src/awareness.rs`), from the controller's vantage point to
the Worker1 NodePort. Workload states are set with tc/netem on Worker1's
replies only: healthy; 10, 30 and 50 % reply loss; 2.5 s reply delay
(all reachable); and 100 % reply loss (unreachable). There are 100
trials per state in one seeded random order. Each trial makes five
attempts and is classified for k = 1, 3 and 5.

- False-RECOVER (a reachable workload classified unreachable), k = 3: at
  most 1 of 100 trials in the healthy and 10 % loss states.
- False-PRESERVE (the unreachable workload classified reachable or
  indeterminate), k = 3: 0 of 100 trials.
- Rates are reported with Wilson intervals and compared with the
  independent-failure prediction p^k, where p is the single-attempt
  failure rate in the same state. A measured rate above p^k is evidence
  that probe failures are correlated.
- Falsified if either threshold is exceeded.

## H5: controller overhead (equivalence)

Budgets, fixed before measurement:

- CPU: 20 millicores.
- Resident memory: 32 MiB.
- Network: 1 KiB/s added host traffic, receive plus transmit.

Measurements:

- The current controller binary (its SHA-256 and commit are recorded).
- 30 one-minute idle windows with the controller and 30 without, in
  alternating order.
- The FA1 RP runs divided into one-minute windows during the partition.

Rules:

- Supported if every one-sided 95 % upper bound is below its budget:
  - idle CPU and memory, and partition CPU and memory: the mean with the
    controller;
  - network: the Welch bound on the difference between windows with and
    without the controller.
- A CPU value below the collector's resolution is reported as
  unmeasured, not as passing.

## Analysis plan

- Durations: medians with BCa bootstrap 95 % intervals, and p95 where
  there are at least 20 values.
- Proportions: Clopper-Pearson exact 95 % intervals.
- Arm comparisons: Fisher exact tests for rates and Cliff's delta for
  durations, with the Holm correction within each hypothesis.
- A run in which the controller never reaches a decision (no
  `Ready=Unknown`, or no decision record) is reported as a non-event or
  missing, never as a correct decision.

## Addendum, 29 October 2026: extension sweep (exploratory)

Added after the main ladder campaign had started and before any run of
the extension. It does not change H1 to H5, their rules, or the
campaigns they are decided on; those verdicts come from the main ladder
campaign alone.

Two further campaigns run after the main ladder and live-writer
campaigns, with the same runner, harness, observers and analysis script:

| Campaign | Arms | Reachable partitions | UW hold | Repetitions |
|---|---|---|---|---|
| E1, tuned tolerations | T5 (`nginx-t5.yaml`), T30 (`nginx-t30.yaml`) | 120 s, 600 s | none | 5 |
| E2, duration sweep | V0, T10, NX, FA1 | 15 s, 60 s, 300 s | none | 3 |

Run order is shuffled with a fresh logged seed per campaign. Results are
reported descriptively (replacement counts with Clopper-Pearson
intervals, medians) as an extension of the ladder, not as tests of
H1 to H5.

## Correction, 30 October 2026: probe-grid impairment

The probe grid did not start on 29 October: its self-test applied the
impairment with a three-band `prio` qdisc, whose default priority map
also sends bulk-class traffic to the impaired band, so the SSH command
that installs the impairment was itself dropped and timed out. No trial
was recorded. The impairment now uses a fourth band that only the
NodePort filter selects (`scripts/ladder/probe_grid.py`). The states,
trial counts, classification rule and H4 decision rule are unchanged.
The probe grid and the overhead windows were run after the live-writer
test, in the same campaign directory and with the same seed.

## Correction, 30 October 2026: live-writer arm assignment

The first live-writer campaign (`campaign-20261029T201737Z`, 20 runs)
wrote its plan with CRLF line endings, so the arm field read as
"fenced\r" and every run took the no-fence branch: the replacement was
released 10 s after suspicion and no fence was installed. All 20 runs
therefore executed the unfenced procedure; they are reported as the
unfenced arm, and none of them counts towards the fenced arm. The runner
now strips carriage returns and writes the plan with LF endings, and the
analysis assigns each run to the arm it executed (a run is fenced only if
its fence was verified). The fenced arm is run in a second campaign with
`LW_ARMS=fenced` and ten runs, under the same H3 rule.
