# Pre-registered addendum 2: kubelet hang, flapping link, and top-ups

Status: committed before any run of the campaigns below. Cite this file by
the hash of the commit that adds it. It is not edited after the first run
starts; any correction goes in a new dated section at the end.

Runner: `scripts/run-extra-campaigns.sh`, which calls
`scripts/ladder/campaign.sh` (conditions `kh` and `fl` added in the same
commit) and `scripts/live-writer/campaign.sh`. Arms, manifests, probes,
observers and analysis rules are those of `docs/hypotheses-midterm2.md`
unless stated here. Every campaign logs its seed and run order before
the first run; every attempt keeps its directory.

## 1. Kubelet hang (kh)

**Fault.** The `k3s-agent` service on Worker1 is stopped for 480 s and
then started again. With `KillMode=process` the kubelet, kube-proxy and
flannel processes stop while the containers and the node's network rules
stay in place, so the workload keeps serving while the node stops
renewing its Lease. This is the hung-kubelet case that the manuscript
argues gives the same signal as Scenario B.

**Arms.** V0, T10 and FA1; 5 runs each (15 runs), one seeded random order.

**H6.** FA1 replaces the original Pod in none of the runs in which the
Worker1 NodePort answers at suspicion, and makes no RECOVER decision in
them. Falsified by any such replacement or RECOVER decision.

Reported descriptively: replacement rate per arm with Clopper-Pearson
intervals; time to replacement for V0 and T10; Worker1 NodePort and
ClusterIP success during the hang; time to Ready after the agent restarts.

## 2. Flapping link (fl)

**Fault.** For 600 s the Scenario B rule (Worker1 to the API server,
TCP 6443) is applied for 75 s and cleared for 30 s, in cycles. Each
75-s down period is long enough for `Ready=Unknown` (about 50 s); each
30-s up period lets the node return to `Ready`. Every transition is
logged.

**Arms.** V0, T10 and FA1; 5 runs each (15 runs), one seeded random order.

**H7.** FA1 neither replaces the original Pod nor makes a RECOVER
decision in any flapping run, and makes one PRESERVE decision per
suspicion episode. Falsified by any replacement, any RECOVER decision, or
a suspicion episode with no decision record.

Reported descriptively: suspicion episodes per run; decisions per episode;
replacement rate per arm; ClusterIP and Worker2 NodePort success.

## 3. Baseline ladder top-up

Two more runs per cell of the existing design (V0, T10, NX, R2, FA1 ×
reachable 120 s, reachable 600 s, unreachable 480 s; 30 runs) in a new
seeded campaign. H1 and H2 are re-evaluated on the pooled runs with the
falsifying conditions of `docs/hypotheses-midterm2.md`, unchanged.

## 4. Live-writer top-up

Twenty more fenced runs in a new seeded campaign. H3 is re-evaluated on
all fenced runs with its falsifying condition unchanged: one commit by
the original writer after the fence falsifies it.

## Stopping rule

No new run starts after the time set in the runner (08:00 EAT for ladder
runs, 07:30 EAT for live-writer runs). Runs not started are reported as
not run; started runs are reported whether completed or aborted.

## Addendum, 7 November 2026: duration-sweep top-up

Added before its first run. Two more runs per cell of the extension
sweep E2 (V0, T10, NX and FA1 under reachable partitions of 15, 60 and
300 s; 24 runs) in a new seeded campaign, pooled with the existing E2
runs and reported as before with Clopper-Pearson intervals. No new run
starts after 12:00 EAT.
