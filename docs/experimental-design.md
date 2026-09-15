# Experimental Design

## Experimental Comparison

The principal comparison is:

1. Default K3s
2. K3s augmented with the Failure-Aware Controller

For each experimental configuration, infrastructure, workload,
storage, network conditions, and resource allocations will remain
identical. The presence of the Failure-Aware Controller will be the
primary architectural difference.

## Experimental Topology

- 1 K3s server/control-plane VM
- 2 K3s worker VMs
- External Rust experimental harness/load generator
- Containerised EMR application
- Relational database
- Persistent storage

## Independent Variables

- Failure scenario
- Controller enabled/disabled
- Worker CPU allocation
- Worker memory allocation
- Network bandwidth
- Network latency
- Packet loss
- Network jitter

## Dependent Variables

- Failure Detection Latency (FDL)
- Failure Classification Latency (FCL)
- Decision Timing Difference (DTD)
- Workload Switching Latency (WSL)
- Service Interruption Duration (SID)
- End-to-End Recovery Latency (ERL)
- P50/P95/P99 request latency
- Request failure rate
- Throughput
- Controller CPU overhead
- Controller memory overhead
- Diagnostic network overhead
- Unnecessary workload recreation
- Incorrect recovery decisions
- Duplicate authoritative execution
- Local service availability

## Controlled Variables

For a given comparison:

- K3s version
- Number of cluster nodes
- VM configuration
- EMR version
- Database version
- Storage configuration
- Container images
- Request rate
- Client concurrency
- Transaction mix
- Experiment duration

## Failure Scenarios

### Scenario A - Genuine Node Failure

The target worker is terminated.

### Scenario B - Control-Plane Partition, Workload Reachable

Communication between the target worker and control plane is severed
while the client-to-workload path remains available.

### Scenario C - Complete Worker Isolation

The worker remains operational but all relevant network paths are
isolated.

### Scenario D - Stateful Database Failure/Recovery

The worker hosting the duplication-sensitive relational database is
failed or isolated and the safe recovery path is evaluated.

### Scenario E - Degraded Network

Bandwidth, latency, packet loss, and/or jitter are varied without
deliberately failing the worker.

## Repetitions

Formal experimental configurations will use a minimum of 30 independent
repetitions.

Pilot runs used for testbed development and validation will not be
included in the formal result set.

## Statistical Reporting

Formal results will report:

- Raw observations
- Mean
- 95% confidence interval
- P50/P95/P99 where applicable
- Effect size where applicable

## Experimental Status

Current stage: testbed provisioning and baseline characterization.
