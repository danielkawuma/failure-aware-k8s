# Pre-Registered Experimental Hypotheses

These hypotheses were defined before collection of the formal
experimental results.

## H1

Post-suspicion operational verification reduces unnecessary workload
recreation when the workload remains reachable outside the
control-plane path, relative to default Kubernetes.

## H2

Event-triggered verification introduces bounded CPU, memory, and
network overhead relative to default Kubernetes under the tested
constrained-resource profiles.

## H3

For duplication-safe stateless workloads, the controller preserves
availability while reducing unnecessary recovery only when the
existing replica remains operationally useful.

## H4

Explicit fencing before recovery prevents duplicate authoritative
execution of duplication-sensitive stateful workloads under the tested
partition scenarios, while adding bounded recovery-decision latency.

## H5

Post-suspicion verification does not alter native failure-detection
latency, while any decision-time cost or benefit is captured separately
by Decision Timing Difference (DTD).

## H6

Under degraded but non-failed network conditions, the proposed mechanism
reduces incorrect recovery decisions when a native suspicion event occurs,
without imposing excessive diagnostic traffic.
