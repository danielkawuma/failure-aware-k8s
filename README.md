# Failure-Aware Kubernetes Orchestration

This repository contains the implementation and experimental evaluation
of a Failure-Aware Controller for Kubernetes under node failures and
network partitions in resource-constrained healthcare cloud environments.

## Research Problem

Kubernetes detects worker unavailability through heartbeat and NodeLease
signals. Loss of control-plane connectivity can therefore produce the
same node-unreachability signal as a genuine worker failure, even when
the affected worker and its workloads remain operational.

The proposed mechanism augments native Kubernetes failure suspicion with
event-triggered verification and workload-aware recovery decisions.

## Proposed Mechanism

The Failure-Aware Controller implements the following pipeline:

Kubernetes Failure Suspicion
→ Post-Suspicion Verification
→ Failure-Awareness Engine
→ PRESERVE / RECOVER
→ Native Kubernetes/CSI Recovery

The Failure-Awareness Engine combines:

- Operational-state awareness
- Workload awareness
- Resource awareness
- Recovery-safety awareness

## Experimental Platform

The initial experimental environment consists of:

- K3s
- 1 control-plane VM
- 2 worker VMs
- Containerised healthcare/EMR workload
- Relational database workload
- Rust-based experimental harness
- Controlled fault and network injection

## Repository Structure

- `controller/` - Failure-Aware Controller implementation
- `harness/` - Rust experimental harness
- `workloads/` - EMR and supporting workload definitions
- `kubernetes/` - Kubernetes/K3s manifests
- `experiments/` - Experiment configurations and raw results
- `analysis/` - Statistical analysis and generated figures
- `scripts/` - Environment and experiment automation
- `docs/` - Architecture, hypotheses and experimental design

## Status

Current phase: Experimental environment setup and implementation.# failure-aware-k8s
