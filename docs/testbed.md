# Experimental Testbed

This document describes the infrastructure, Kubernetes configuration,
workload environment, resource profiles, networking, storage, and
installation procedure used for the experimental evaluation of the
Failure-Aware Kubernetes Controller.

The testbed configuration forms part of the reproducibility record for
the project. Configuration changes made after formal experimentation
begins must be documented and version-controlled.

---

## Infrastructure Overview

The experimental environment is hosted on **Proxmox** and consists of
three virtual machines running K3s.

| Node | Role | Hostname | IP Address | vCPU | RAM | Disk | OS |
|---|---|---|---|---:|---:|---:|---|
| Server | K3s control plane | `k3s-server` | `102.34.160.89` | 4 | 4 GB | 100 GB | `Ubuntu 24.04.5 LTS, Kernel: 6.8.0-59-generic` |
| Worker 1 | Primary fault target | `k3s-worker1` | `102.34.160.87` | 4 | 4 GB | 100 GB | `Ubuntu 24.04.5 LTS, Kernel: 6.8.0-59-generic` |
| Worker 2 | Recovery target | `k3s-worker2` | `102.34.160.103` | 4 | 4 GB | 100 GB | `Ubuntu 24.04.5 LTS, Kernel: 6.8.0-59-generic` |

The Rust experimental harness and external workload generator run from
a separate client machine outside the K3s cluster.

Where possible, the VM addresses should remain fixed throughout the
formal experimental campaign.

---

## Kubernetes Configuration

The initial Kubernetes configuration is:

- Kubernetes distribution: **K3s**
- K3s version: **v1.36.4+k3s1**
- Kubernetes version: **[K8S_VERSION]**
- Container runtime: **containerd**
- Configuration: **Default K3s configuration**
- CNI: **Flannel**
- Cluster DNS: **CoreDNS**
- Ingress Controller: **Traefik**
- Service Load Balancer: **ServiceLB**
- Initial storage provisioner: **Local Path Provisioner**
- Formal experimental CSI implementation: **Flannel**
- Cluster domain: **[CLUSTER_DOMAIN]**
- Pod CIDR: **[POD_CIDR]**
- Service CIDR: **[SERVICE_CIDR]**

These components should remain constant between the default K3s baseline
and the K3s + Failure-Aware Controller experiments unless the component
itself is explicitly being evaluated as an independent variable.

---

## Node Roles

### `k3s-server`

Role: **K3s control plane**

Primary responsibilities include:

- Kubernetes API Server
- Controller Manager
- Scheduler
- cluster datastore
- Node lifecycle management
- NodeLease observation
- cluster-state management

The Failure-Aware Controller will consume native Kubernetes state through
the Kubernetes API rather than replacing these control-plane mechanisms.

---

### `k3s-worker1`

Role: **Primary fault-injection target**

This worker will primarily host workloads used for:

- genuine node-failure experiments
- control-plane partition experiments
- complete-isolation experiments
- degraded-network experiments
- workload reachability verification
- stateful workload experiments where applicable

The node will be labelled:

```text
experiment-role=fault-target
```

---

### `k3s-worker2`

Role: **Recovery target**

This worker provides available compute capacity when workloads on
`k3s-worker1` require recovery.

The node will be labelled:

```text
experiment-role=recovery-target
```

This separation allows a workload affected by a Worker 1 failure or
partition to be recovered onto Worker 2 without modifying the native
Kubernetes scheduler.

![alt text](image.png)

---

## External Experimental Client

The external experimental client is separate from the K3s cluster.

Client details:

- Host: **[PC/LAPTOP NAME]**
- OS: **[OS/VERSION]**
- CPU: **[CPU MODEL / CORES]**
- RAM: **[RAM]**
- Network connection: **[WIRED / WIFI / OTHER]**

The external client will run:

- Rust experimental harness
- workload generation
- experiment coordination
- fault orchestration
- event timestamping
- result collection
- statistical analysis

Keeping the load generator outside the K3s workers prevents the
experimental harness itself from consuming the constrained CPU and
memory resources being measured on the worker nodes.

It also provides an independent client path for determining whether an
application remains operationally useful when its worker loses
control-plane connectivity.

---

## Workload Configuration

The experimental workload will use an actual containerised Electronic
Medical Record application.

Healthcare application:

- EMR system: **[EMR NAME]**
- EMR version: **[VERSION]**
- Application deployment model: **[DEPLOYMENT MODEL]**
- Application tier: **[STATELESS / OTHER]**
- Database: **[MYSQL / MARIADB / POSTGRESQL / OTHER]**
- Database version: **[VERSION]**

The application tier represents the duplication-safe portion of the
workload where appropriate.

The relational database represents a
**duplication-sensitive stateful workload** because concurrent
authoritative execution may create consistency risks.

The workload should expose repeatable operations suitable for automated
experimental testing.

Examples:

- read operation: **[ENDPOINT / ACTION]**
- write operation: **[ENDPOINT / ACTION]**
- health endpoint: **[ENDPOINT]**

The exact workload configuration will be frozen before formal
experimental data collection.

---

## Storage Configuration

Persistent database data must not rely on ephemeral container storage.

The storage path is expected to follow:

```text
EMR Application
      |
      v
Relational Database
      |
      v
PersistentVolumeClaim
      |
      v
CSI / Persistent Storage
```

Initial development storage:

- StorageClass: **[STORAGE_CLASS]**
- Provisioner: **[PROVISIONER]**
- Access mode: **[RWO / RWOP / OTHER]**
- Volume size: **[SIZE]**
- Volume type: **[LOCAL / LONGHORN / CEPH / NFS / OTHER]**

The K3s Local Path Provisioner may be used during initial application
deployment and development.

For formal stateful recovery experiments, a CSI-backed storage system
capable of supporting recovery on another worker will be selected and
documented.

Formal experimental storage:

- CSI implementation: **[CSI_IMPLEMENTATION]**
- CSI version: **[VERSION]**
- StorageClass: **[STORAGE_CLASS]**
- Access mode: **[RWO / RWOP]**
- Replication factor: **[VALUE / N/A]**
- Persistent volume size: **[SIZE]**

Native RWO/RWOP access-mode enforcement will remain part of the storage
stack. However, the project does not assume that these mechanisms alone
constitute sufficient fencing under the target network-partition
scenarios.

Explicit fencing will therefore be evaluated for recovery of
duplication-sensitive stateful workloads before a replacement instance
is permitted to become authoritative.

---

## Resource Profiles

### Development Profile

The initial development configuration is:

| Node | vCPU | RAM |
|---|---:|---:|
| `k3s-server` | 4 | 4 GB |
| `k3s-worker1` | 4 | 4 GB |
| `k3s-worker2` | 4 | 4 GB |

This profile is intended to provide sufficient capacity for initial
cluster deployment, workload deployment, controller development, and
pilot experiments.

---

### Formal Experimental Profiles

Resource constraints will later be introduced as controlled
experimental variables.

Initial candidate profiles are:

#### Low Resource Profile

- CPU: **1 vCPU**
- RAM: **1 GB**

#### Medium Resource Profile

- CPU: **2 vCPU**
- RAM: **2 GB**

#### Higher Resource Profile

- CPU: **4 vCPU**
- RAM: **4 GB**

The final profiles will be frozen after preliminary testbed
characterisation.

For a given baseline-versus-controller comparison, worker CPU and memory
allocations must remain identical.

---

## Network Configuration

The normal network profile should be recorded before experimental fault
injection.

Baseline network:

- available bandwidth: **[VALUE]**
- round-trip latency: **[VALUE]**
- packet loss: **[VALUE]**
- jitter: **[VALUE]**

The experimental network condition is represented by:

```text
N = {B, L, P, J}
```

where:

- `B` = available bandwidth
- `L` = round-trip latency
- `P` = packet-loss rate
- `J` = network jitter

Experimental network controls may include:

- `tc/netem`
- `iptables` / `nftables`
- Chaos Mesh
- other documented fault-injection mechanisms

The network configuration must support selective partitions.

In particular, Scenario B requires:

```text
k3s-worker1  X  k3s-server

while

External Client  --->  k3s-worker1 / workload
```

The worker-to-control-plane path must therefore be disrupted without
simultaneously destroying the independent client-to-workload path.

---

## Primary Experimental Comparison

The principal experimental comparison is:

```text
DEFAULT K3s
Failure-Aware Controller OFF
```

versus:

```text
K3s + FAILURE-AWARE CONTROLLER
Failure-Aware Controller ON
```

For each comparison, the following must remain fixed:

- K3s version
- Kubernetes version
- CNI
- Ingress Controller
- workload version
- database version
- storage configuration
- worker resource profile
- network condition
- fault condition
- request rate
- client concurrency
- transaction mix
- experiment duration

The intended architectural difference is the presence or absence of the
Failure-Aware Controller.

---

## Failure Scenarios

The experimental evaluation contains five principal scenarios.

### Scenario A — Genuine Worker Failure

The target worker is terminated.

Expected operational state:

```text
unreachable
```

Primary measurements include:

- Failure Detection Latency
- Failure Classification Latency
- Decision Timing Difference
- Workload Switching Latency
- Service Interruption Duration
- End-to-End Recovery Latency

---

### Scenario B — Control-Plane Partition, Workload Reachable

Communication between `k3s-worker1` and `k3s-server` is severed while
the external client-to-workload path remains available.

Expected operational state:

```text
reachable_outside_control_plane
```

This is the primary scenario demonstrating the ambiguity addressed by
the project.

The expected condition is:

```text
Kubernetes view:

k3s-worker1
     |
     X
     |
k3s-server

Node -> Unknown / Unreachable


Independent client view:

External Client
     |
     | HTTP/Application traffic
     v
EMR on k3s-worker1

Service -> Still Available
```

Primary measurements include:

- Failure Classification Latency
- Decision Timing Difference
- unnecessary workload recreation
- local service availability
- application latency
- diagnostic overhead

---

### Scenario C — Complete Worker Isolation

`k3s-worker1` remains operational but all relevant network paths are
isolated.

Expected operational state:

```text
unreachable
```

The Failure-Aware Controller intentionally does not claim that this
observation proves a physical worker crash because the same externally
observable state may result from complete network isolation.

---

### Scenario D — Stateful Database Failure and Recovery

The worker hosting the duplication-sensitive relational database is
failed or isolated.

The experiment evaluates:

- recovery decision
- explicit fencing
- storage authority transition
- volume detach/attach
- database startup
- database crash recovery
- duplicate authoritative execution

Recovery must follow the safety sequence:

```text
RECOVER requested
       |
       v
Duplication-sensitive workload?
       |
      YES
       |
       v
Explicit fencing
       |
       v
Verify old authority excluded
       |
       v
Permit native Kubernetes recovery
       |
       v
Replacement becomes authoritative
```

---

### Scenario E — Degraded Network

The worker remains operational while network quality is degraded using
controlled changes to:

- bandwidth
- latency
- packet loss
- jitter

No genuine worker failure is deliberately introduced.

The experiment measures whether degradation causes inappropriate
recovery decisions and how much diagnostic traffic is introduced by
the Failure-Aware Controller.

---

## Baseline Test Workload

Before deploying the full EMR, a lightweight HTTP workload may be used
to verify:

- scheduling
- Pod networking
- Service exposure
- worker placement
- external client reachability
- selective control-plane partition behaviour

Suggested initial application:

```text
nginx
```

Suggested namespace:

```text
failure-aware
```

The test workload should be scheduled specifically onto:

```text
k3s-worker1
```

using the experimental node label.

Example node selector:

```yaml
nodeSelector:
  experiment-role: fault-target
```

The temporary workload can be exposed through a NodePort during early
development so that the external client can independently verify
service reachability.

Record:

- application: **[APPLICATION]**
- namespace: **[NAMESPACE]**
- node: **[NODE]**
- service type: **[SERVICE TYPE]**
- external URL: **[URL]**

---

# K3s Installation and Cluster Bootstrap

This section documents the procedure used to install and bootstrap the
experimental K3s cluster.

The installation procedure is retained so that the cluster can be
recreated using the same software versions and configuration.

---

## Operating System Preparation

All K3s nodes should use the same operating-system distribution and
version where practical.

Record the operating system on each node:

```bash
cat /etc/os-release
```

Record the kernel:

```bash
uname -r
```

Update each node:

```bash
sudo apt update
sudo apt upgrade -y
```

Install the basic administrative tools:

```bash
sudo apt install -y curl vim git jq
```

---

## Configure Node Hostnames

On the control-plane node:

```bash
sudo hostnamectl set-hostname k3s-server
```

On Worker 1:

```bash
sudo hostnamectl set-hostname k3s-worker1
```

On Worker 2:

```bash
sudo hostnamectl set-hostname k3s-worker2
```

Verify:

```bash
hostname
```

Record the node addresses:

```bash
hostname -I
```

---

## Optional Local Name Resolution

Where DNS resolution is not available, add the experimental nodes to
`/etc/hosts`.

Edit:

```bash
sudo nano /etc/hosts
```

Add:

```text
[SERVER_IP]   k3s-server
[WORKER1_IP]  k3s-worker1
[WORKER2_IP]  k3s-worker2
```

Verify:

```bash
ping -c 3 k3s-server
ping -c 3 k3s-worker1
ping -c 3 k3s-worker2
```

---

## Install the K3s Server

On `k3s-server`, install K3s:

```bash
curl -sfL https://get.k3s.io | sh -
```

Verify:

```bash
sudo systemctl status k3s
```

Check cluster state:

```bash
sudo k3s kubectl get nodes -o wide
```

Initially, the expected cluster contains:

```text
k3s-server    Ready    control-plane,master
```

---

## Record and Pin the K3s Version

Determine the installed version:

```bash
sudo k3s --version
```

Record:

```text
K3s version: [K3S_VERSION]
```

Also record the Kubernetes version:

```bash
sudo k3s kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,K8S:.status.nodeInfo.kubeletVersion
```

For reproducible future installation, pin the recorded K3s version
rather than relying on the moving stable channel:

```bash
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION='[K3S_VERSION]' sh -
```

Example:

```bash
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION='v1.36.4+k3s1' sh -
```

The exact version actually used in the formal experiments must be
recorded in this document.

---

## Obtain the Worker Join Token

On `k3s-server`:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

The token is a cluster secret.

**Do not store the token in this repository.**

The repository should also exclude:

- K3s join tokens
- kubeconfig credentials
- database passwords
- TLS private keys
- API secrets
- other authentication material

---

## Join Worker 1

On `k3s-worker1`:

```bash
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION='[K3S_VERSION]' \
K3S_URL=https://[SERVER_IP]:6443 \
K3S_TOKEN='[K3S_TOKEN]' sh -
```

Verify:

```bash
sudo systemctl status k3s-agent
```

From `k3s-server`:

```bash
sudo k3s kubectl get nodes -o wide
```

Expected:

```text
k3s-server     Ready
k3s-worker1    Ready
```

---

## Join Worker 2

On `k3s-worker2`:

```bash
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION='[K3S_VERSION]' \
K3S_URL=https://[SERVER_IP]:6443 \
K3S_TOKEN='[K3S_TOKEN]' sh -
```

Verify:

```bash
sudo systemctl status k3s-agent
```

Then verify the full cluster from `k3s-server`:

```bash
sudo k3s kubectl get nodes -o wide
```

Expected:

```text
NAME          STATUS   ROLES
k3s-server    Ready    control-plane,master
k3s-worker1   Ready    <none>
k3s-worker2   Ready    <none>
```

---

# Native K3s Components

The experiment initially retains the standard K3s components.

| Function | Implementation |
|---|---|
| Kubernetes distribution | K3s |
| Container runtime | containerd |
| CNI | Flannel |
| Cluster DNS | CoreDNS |
| Ingress Controller | Traefik |
| Service Load Balancer | ServiceLB |
| Initial storage | Local Path Provisioner |
| Formal experimental storage | `[CSI_IMPLEMENTATION]` |

These components are kept constant between baseline and proposed-system
experiments.

---

## Verify System Components

Inspect the K3s system workloads:

```bash
sudo k3s kubectl get pods -n kube-system -o wide
```

Inspect all cluster workloads:

```bash
sudo k3s kubectl get pods -A -o wide
```

Before baseline experimentation, there should be no unexplained
long-running states such as:

```text
CrashLoopBackOff
ImagePullBackOff
Pending
```

Any such condition must be resolved or documented before formal
measurements begin.

---

# CNI Configuration

The initial experimental cluster uses the default **Flannel CNI**.

Flannel provides the Kubernetes Pod network used for communication
between workloads running across the cluster.

The CNI implementation remains unchanged between:

```text
Default K3s
Controller OFF
```

and:

```text
K3s + Failure-Aware Controller
Controller ON
```

This prevents the networking implementation from becoming a confounding
variable.

Record:

```text
CNI: Flannel
CNI version: [VERSION]
Configuration: [DEFAULT / MODIFIED]
```

---

# Ingress Configuration

The initial K3s environment uses **Traefik** as the Ingress Controller.

Traefik is installed as a packaged K3s component unless explicitly
disabled during K3s installation.

The experiment retains Traefik so that replacing the Ingress Controller
does not introduce an unnecessary architectural difference from the
initial K3s environment.

Verify Traefik:

```bash
sudo k3s kubectl get pods -n kube-system | grep traefik
```

Inspect its Service:

```bash
sudo k3s kubectl get svc -n kube-system | grep traefik
```

Inspect the K3s-managed Helm charts:

```bash
sudo k3s kubectl get helmchart -n kube-system
```

Record:

```text
Ingress Controller: Traefik
Traefik version: [VERSION]
Configuration: [DEFAULT / MODIFIED]
```

K3s packaged component manifests are maintained under:

```text
/var/lib/rancher/k3s/server/manifests/
```

K3s-managed packaged manifests should not be manually modified without
documenting the change.

---

# NodeLease and Heartbeat Verification

NodeLease objects provide the native Kubernetes heartbeat mechanism that
forms the starting point of the Failure-Aware Controller.

List NodeLeases:

```bash
sudo k3s kubectl get leases -n kube-node-lease
```

Expected:

```text
k3s-server
k3s-worker1
k3s-worker2
```

Inspect Worker 1's Lease:

```bash
sudo k3s kubectl get lease k3s-worker1 \
  -n kube-node-lease -o yaml
```

The Lease should contain information similar to:

```yaml
spec:
  holderIdentity: k3s-worker1
  renewTime: "..."
```

Observe the renewal timestamp:

```bash
watch -n 2 \
"sudo k3s kubectl get lease k3s-worker1 \
-n kube-node-lease \
-o custom-columns=NODE:.metadata.name,RENEW:.spec.renewTime"
```

The `renewTime` should change periodically while the worker maintains
communication with the control plane.

Simultaneously observe node state:

```bash
sudo k3s kubectl get nodes -w
```

The relationship relevant to this research is:

```text
k3s-worker1 kubelet
        |
        | Lease renewal
        v
Kubernetes API Server
        |
        v
Node lifecycle monitoring
        |
        v
Ready / Unknown
```

The Failure-Aware Controller does **not** replace this mechanism.

It consumes the native Kubernetes failure-suspicion signal after the
node-health mechanism raises suspicion.

---

# Experimental Node Labels

Label Worker 1 as the fault target:

```bash
sudo k3s kubectl label node k3s-worker1 \
  experiment-role=fault-target
```

Label Worker 2 as the recovery target:

```bash
sudo k3s kubectl label node k3s-worker2 \
  experiment-role=recovery-target
```

Verify:

```bash
sudo k3s kubectl get nodes --show-labels
```

Expected experimental roles:

| Node | Experimental Role |
|---|---|
| `k3s-server` | Control plane |
| `k3s-worker1` | Fault/partition target |
| `k3s-worker2` | Recovery target |

These labels are used to control experimental workload placement without
replacing or modifying the Kubernetes scheduler.

---

# Native K3s Baseline Checks

Before enabling the Failure-Aware Controller, capture the native K3s
environment.

Run:

```bash
sudo k3s kubectl get nodes -o wide
```

```bash
sudo k3s kubectl get leases -n kube-node-lease
```

```bash
sudo k3s kubectl describe node k3s-worker1
```

```bash
sudo k3s kubectl get pods -A -o wide
```

Record the normal Worker 1 state:

```text
Ready = True
```

Inspect current taints:

```bash
sudo k3s kubectl get node k3s-worker1 \
  -o jsonpath='{.spec.taints}'
```

These observations establish the healthy baseline before fault
injection.

---

# Monitoring During Pilot Experiments

During early experiments, multiple views should be maintained.

## Terminal 1 — Node State

On `k3s-server`:

```bash
sudo k3s kubectl get nodes -w
```

## Terminal 2 — Workload State

```bash
sudo k3s kubectl get pods \
  -n failure-aware \
  -o wide -w
```

## Terminal 3 — Worker Lease

```bash
watch -n 2 \
"sudo k3s kubectl get lease k3s-worker1 \
-n kube-node-lease \
-o custom-columns=NODE:.metadata.name,RENEW:.spec.renewTime"
```

## External Client — Application Reachability

From the external experimental client:

```bash
watch -n 1 \
"curl -s -o /dev/null -w '%{http_code}\n' \
http://[WORKER1_IP]:[PORT]"
```

During normal operation, repeated successful responses should be
observed.

These simultaneous views allow the experiment to compare:

```text
CONTROL-PLANE VIEW
NodeLease / Node condition

versus

CLIENT VIEW
Application reachability
```

This distinction is central to the research problem.

---

# Rust Experimental Harness

The formal experimental harness will run outside the K3s cluster.

The harness will be implemented in Rust and will eventually provide:

- workload generation
- concurrent client requests
- request timestamps
- latency measurement
- request success/failure recording
- Kubernetes event observation
- fault-injection coordination
- experiment start/stop control
- raw result export

The harness is conceptually separate from the Failure-Aware Controller.

```text
Rust Experimental Harness
        |
        | drives and measures
        v
Experimental K3s Environment


Failure-Aware Controller
        |
        | system under test
        v
Kubernetes recovery behaviour
```

The harness will record timestamps including:

```text
t_failure
t_suspect
t_classified
t_authorized
t_restored
t_last_success
t_first_success
```

These timestamps will be used to derive the formal experimental metrics.

---

# Experimental Measurements

Principal timing measurements include:

- Failure Detection Latency (FDL)
- Failure Classification Latency (FCL)
- Decision Timing Difference (DTD)
- Workload Switching Latency (WSL)
- Service Interruption Duration (SID)
- End-to-End Recovery Latency (ERL)

Application measurements include:

- P50 response latency
- P95 response latency
- P99 response latency
- request failure rate
- throughput
- local service availability

Controller overhead measurements include:

- CPU consumption
- memory consumption
- diagnostic network bytes
- number of diagnostic probes per event

Correctness measurements include:

- unnecessary workload recreation
- incorrect recovery decisions
- duplicate authoritative execution
- successful stateful recovery

---

# Formal Experimental Repetitions

Pilot runs will first be used to validate:

- fault injection
- environment reset
- timestamps
- workload generation
- metrics
- controller behaviour
- data collection

Pilot runs are not part of the formal headline result set.

Once the experimental configuration is frozen, each formal
configuration will be executed for a minimum of:

```text
30 independent repetitions
```

Formal results will report:

- raw observations
- mean
- 95% confidence interval
- P50/P95/P99 where applicable
- effect size where applicable

---

# Reproducibility Requirements

The experimental repository will preserve:

- K3s version
- Kubernetes version
- operating-system version
- kernel version
- container image versions/digests
- CNI configuration
- Ingress configuration
- CSI configuration
- EMR version
- database version
- experiment configurations
- fault-injection scripts
- Rust harness source
- Failure-Aware Controller source
- raw experimental data
- statistical analysis scripts
- generated figures and tables

Secrets and credentials must not be committed.

The project will eventually expose a single reproduction entry point,
for example:

```bash
make reproduce
```

or:

```bash
cargo xtask reproduce
```

The reproduction workflow will be implemented incrementally as the
experimental environment matures.

---

# Cluster Bootstrap Verification Checklist

Before deploying the formal EMR workload or beginning baseline
experiments, verify:

- [ ] `k3s-server` reports `Ready`
- [ ] `k3s-worker1` reports `Ready`
- [ ] `k3s-worker2` reports `Ready`
- [ ] All three NodeLease objects exist
- [ ] Worker NodeLeases renew normally
- [ ] Flannel networking is operational
- [ ] CoreDNS is operational
- [ ] Traefik is operational
- [ ] containerd is operational
- [ ] No unexplained system Pods are failing
- [ ] Worker experimental labels are configured
- [ ] K3s version has been recorded
- [ ] Kubernetes version has been recorded
- [ ] OS version has been recorded
- [ ] Kernel version has been recorded
- [ ] Node IP addresses have been recorded
- [ ] No cluster secrets have been committed

---

# Experimental Implementation Status

## Completed

- [ ] Git repository initialized
- [ ] Hypotheses pre-registered
- [ ] Experimental design committed
- [ ] Three Proxmox VMs provisioned
- [ ] K3s server installed
- [ ] Worker 1 joined
- [ ] Worker 2 joined
- [ ] All nodes `Ready`
- [ ] NodeLeases verified
- [ ] Flannel verified
- [ ] CoreDNS verified
- [ ] Traefik verified
- [ ] Experimental node labels configured

## Baseline Preparation

- [ ] Temporary HTTP workload deployed
- [ ] Workload pinned to `k3s-worker1`
- [ ] External client reachability verified
- [ ] Native healthy-state baseline captured
- [ ] Scenario B selective partition validated
- [ ] Native K3s behaviour recorded

## Application Environment

- [ ] EMR selected
- [ ] EMR container deployed
- [ ] Relational database deployed
- [ ] Persistent storage configured
- [ ] Read operation automated
- [ ] Write operation automated
- [ ] Application health check identified

## Experimental Tooling

- [ ] Rust harness initialized
- [ ] Request generator implemented
- [ ] Latency recording implemented
- [ ] Kubernetes event observation implemented
- [ ] Fault-injection scripts implemented
- [ ] Raw-data export implemented

## Failure-Aware Controller

- [ ] Failure-Suspicion Listener implemented
- [ ] Post-Suspicion Verification implemented
- [ ] Operational-state assessment implemented
- [ ] Workload awareness implemented
- [ ] Resource awareness implemented
- [ ] Recovery-safety awareness implemented
- [ ] PRESERVE decision implemented
- [ ] RECOVER decision implemented
- [ ] Explicit fencing implemented
- [ ] Recovery actuation implemented

## Formal Evaluation

- [ ] Pilot experiments completed
- [ ] Formal configuration frozen
- [ ] Baseline repetitions completed
- [ ] Controller repetitions completed
- [ ] Scenario A completed
- [ ] Scenario B completed
- [ ] Scenario C completed
- [ ] Scenario D completed
- [ ] Scenario E completed
- [ ] Statistical analysis completed
- [ ] Production validation completed