use anyhow::{Result, anyhow};
use k8s_openapi::api::core::v1::{Node, Pod};
use kube::{Api, Client};
use serde::Deserialize;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceState {
    Available,
    Insufficient,
    Unavailable,
}

#[derive(Debug, Clone)]
pub struct ResourceAwareness {
    pub candidate_node: String,
    pub state: ResourceState,

    pub node_ready: bool,
    pub node_schedulable: bool,
    pub labels_match: bool,

    pub allocatable_cpu_millicores: u64,
    pub requested_cpu_millicores: u64,
    pub remaining_cpu_millicores: u64,
    pub required_cpu_millicores: u64,

    pub allocatable_memory_mib: u64,
    pub requested_memory_mib: u64,
    pub remaining_memory_mib: u64,
    pub required_memory_mib: u64,

    pub reliability_score: f64,
    pub multi_candidate_selection: bool,
}

#[derive(Debug, Clone)]
struct CandidateEvaluation {
    node_name: String,
    ready: bool,
    schedulable: bool,
    labels_match: bool,

    allocatable_cpu_millicores: u64,
    requested_cpu_millicores: u64,
    remaining_cpu_millicores: u64,

    allocatable_memory_mib: u64,
    requested_memory_mib: u64,
    remaining_memory_mib: u64,

    reliability_score: f64,
    eligible: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct NodeHistory {
    #[serde(default = "default_uptime_ratio")]
    uptime_ratio: f64,

    #[serde(default)]
    recent_failures: u64,

    #[serde(default)]
    successful_recoveries: u64,

    #[serde(default)]
    failed_recoveries: u64,
}

fn default_uptime_ratio() -> f64 {
    0.5
}

fn node_ready(node: &Node) -> bool {
    node.status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .and_then(|conditions| {
            conditions
                .iter()
                .find(|condition| condition.type_ == "Ready")
        })
        .map(|condition| condition.status == "True")
        .unwrap_or(false)
}

fn node_schedulable(node: &Node) -> bool {
    !node
        .spec
        .as_ref()
        .and_then(|spec| spec.unschedulable)
        .unwrap_or(false)
}

fn labels_match(node: &Node, required_labels: &HashMap<String, String>) -> bool {
    required_labels.iter().all(|(key, expected_value)| {
        node.metadata
            .labels
            .as_ref()
            .and_then(|labels| labels.get(key))
            == Some(expected_value)
    })
}

fn parse_cpu_millicores(value: &str) -> Result<u64> {
    if let Some(nano) = value.strip_suffix('n') {
        let nano: u64 = nano.parse()?;
        return Ok((nano + 999_999) / 1_000_000);
    }

    if let Some(micro) = value.strip_suffix('u') {
        let micro: u64 = micro.parse()?;
        return Ok((micro + 999) / 1_000);
    }

    if let Some(milli) = value.strip_suffix('m') {
        return Ok(milli.parse()?);
    }

    let cores: f64 = value.parse()?;
    Ok((cores * 1000.0).ceil() as u64)
}

fn parse_memory_mib(value: &str) -> Result<u64> {
    if let Some(kib) = value.strip_suffix("Ki") {
        let kib: f64 = kib.parse()?;
        return Ok((kib / 1024.0).ceil() as u64);
    }

    if let Some(mib) = value.strip_suffix("Mi") {
        let mib: f64 = mib.parse()?;
        return Ok(mib.ceil() as u64);
    }

    if let Some(gib) = value.strip_suffix("Gi") {
        let gib: f64 = gib.parse()?;
        return Ok((gib * 1024.0).ceil() as u64);
    }

    if let Some(tib) = value.strip_suffix("Ti") {
        let tib: f64 = tib.parse()?;
        return Ok((tib * 1024.0 * 1024.0).ceil() as u64);
    }

    if let Some(kb) = value.strip_suffix('K') {
        let kb: f64 = kb.parse()?;
        return Ok((kb * 1000.0 / 1024.0 / 1024.0).ceil() as u64);
    }

    if let Some(mb) = value.strip_suffix('M') {
        let mb: f64 = mb.parse()?;
        return Ok((mb * 1000.0 * 1000.0 / 1024.0 / 1024.0).ceil() as u64);
    }

    if let Some(gb) = value.strip_suffix('G') {
        let gb: f64 = gb.parse()?;
        return Ok((gb * 1000.0 * 1000.0 * 1000.0 / 1024.0 / 1024.0).ceil() as u64);
    }

    if value.chars().all(|c| c.is_ascii_digit()) {
        let bytes: f64 = value.parse()?;
        return Ok((bytes / 1024.0 / 1024.0).ceil() as u64);
    }

    Err(anyhow!("Unsupported Kubernetes memory quantity: {}", value))
}

fn node_allocatable(node: &Node) -> Result<(u64, u64)> {
    let node_name = node.metadata.name.as_deref().unwrap_or("<unknown>");

    let allocatable = node
        .status
        .as_ref()
        .and_then(|status| status.allocatable.as_ref())
        .ok_or_else(|| anyhow!("Node {} has no allocatable resource data", node_name))?;

    let cpu_quantity = allocatable
        .get("cpu")
        .ok_or_else(|| anyhow!("Node {} has no allocatable CPU value", node_name))?;

    let memory_quantity = allocatable
        .get("memory")
        .ok_or_else(|| anyhow!("Node {} has no allocatable memory value", node_name))?;

    Ok((
        parse_cpu_millicores(&cpu_quantity.0)?,
        parse_memory_mib(&memory_quantity.0)?,
    ))
}

fn container_requests(pod: &Pod) -> Result<(u64, u64)> {
    let spec = match pod.spec.as_ref() {
        Some(spec) => spec,
        None => return Ok((0, 0)),
    };

    let mut app_cpu = 0u64;
    let mut app_memory = 0u64;

    for container in &spec.containers {
        if let Some(resources) = container.resources.as_ref() {
            if let Some(requests) = resources.requests.as_ref() {
                if let Some(cpu) = requests.get("cpu") {
                    app_cpu = app_cpu.saturating_add(parse_cpu_millicores(&cpu.0)?);
                }

                if let Some(memory) = requests.get("memory") {
                    app_memory = app_memory.saturating_add(parse_memory_mib(&memory.0)?);
                }
            }
        }
    }

    let mut max_init_cpu = 0u64;
    let mut max_init_memory = 0u64;

    if let Some(init_containers) = spec.init_containers.as_ref() {
        for container in init_containers {
            let mut init_cpu = 0u64;
            let mut init_memory = 0u64;

            if let Some(resources) = container.resources.as_ref() {
                if let Some(requests) = resources.requests.as_ref() {
                    if let Some(cpu) = requests.get("cpu") {
                        init_cpu = parse_cpu_millicores(&cpu.0)?;
                    }

                    if let Some(memory) = requests.get("memory") {
                        init_memory = parse_memory_mib(&memory.0)?;
                    }
                }
            }

            max_init_cpu = max_init_cpu.max(init_cpu);
            max_init_memory = max_init_memory.max(init_memory);
        }
    }

    let mut effective_cpu = app_cpu.max(max_init_cpu);
    let mut effective_memory = app_memory.max(max_init_memory);

    if let Some(overhead) = spec.overhead.as_ref() {
        if let Some(cpu) = overhead.get("cpu") {
            effective_cpu = effective_cpu.saturating_add(parse_cpu_millicores(&cpu.0)?);
        }

        if let Some(memory) = overhead.get("memory") {
            effective_memory = effective_memory.saturating_add(parse_memory_mib(&memory.0)?);
        }
    }

    Ok((effective_cpu, effective_memory))
}

async fn requested_resources_on_node(client: Client, node_name: &str) -> Result<(u64, u64)> {
    let pods: Api<Pod> = Api::all(client);
    let pod_list = pods.list(&Default::default()).await?;

    let mut requested_cpu = 0u64;
    let mut requested_memory = 0u64;

    for pod in pod_list.items {
        let phase = pod
            .status
            .as_ref()
            .and_then(|status| status.phase.as_deref())
            .unwrap_or("");

        if phase == "Succeeded" || phase == "Failed" {
            continue;
        }

        let assigned_node = pod.spec.as_ref().and_then(|spec| spec.node_name.as_deref());

        if assigned_node != Some(node_name) {
            continue;
        }

        let (cpu, memory) = container_requests(&pod)?;
        requested_cpu = requested_cpu.saturating_add(cpu);
        requested_memory = requested_memory.saturating_add(memory);
    }

    Ok((requested_cpu, requested_memory))
}

fn reliability_score(history: &NodeHistory) -> f64 {
    let uptime = history.uptime_ratio.clamp(0.0, 1.0);

    let recent_failure_health = 1.0 / (1.0 + history.recent_failures as f64);

    let recovery_total = history.successful_recoveries + history.failed_recoveries;

    let recovery_stability = if recovery_total == 0 {
        0.5
    } else {
        history.successful_recoveries as f64 / recovery_total as f64
    };

    0.60 * uptime + 0.25 * recent_failure_health + 0.15 * recovery_stability
}

fn load_history() -> Result<HashMap<String, NodeHistory>> {
    let configured_path = env::var("FAILURE_AWARE_NODE_HISTORY")
        .unwrap_or_else(|_| "controller/config/node-history.json".to_string());

    let fallback_path = "config/node-history.json";

    let chosen_path = if Path::new(&configured_path).exists() {
        configured_path
    } else if Path::new(fallback_path).exists() {
        fallback_path.to_string()
    } else {
        println!("[RELIABILITY] history file not found; using neutral reliability values");
        return Ok(HashMap::new());
    };

    let contents = fs::read_to_string(&chosen_path)?;
    let history: HashMap<String, NodeHistory> = serde_json::from_str(&contents)?;

    println!("[RELIABILITY] loaded node history from {}", chosen_path);

    Ok(history)
}

async fn evaluate_one_candidate(
    client: Client,
    node: &Node,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_labels: &HashMap<String, String>,
    history: &HashMap<String, NodeHistory>,
) -> Result<CandidateEvaluation> {
    let node_name = node
        .metadata
        .name
        .clone()
        .ok_or_else(|| anyhow!("Candidate node has no metadata.name"))?;

    let ready = node_ready(node);
    let schedulable = node_schedulable(node);
    let labels_ok = labels_match(node, required_labels);

    let (allocatable_cpu, allocatable_memory) = node_allocatable(node)?;

    let (requested_cpu, requested_memory) = requested_resources_on_node(client, &node_name).await?;

    let remaining_cpu = allocatable_cpu.saturating_sub(requested_cpu);

    let remaining_memory = allocatable_memory.saturating_sub(requested_memory);

    let score = reliability_score(history.get(&node_name).unwrap_or(&NodeHistory::default()));

    let sufficient =
        remaining_cpu >= required_cpu_millicores && remaining_memory >= required_memory_mib;

    let eligible = ready && schedulable && labels_ok && sufficient;

    Ok(CandidateEvaluation {
        node_name,
        ready,
        schedulable,
        labels_match: labels_ok,

        allocatable_cpu_millicores: allocatable_cpu,
        requested_cpu_millicores: requested_cpu,
        remaining_cpu_millicores: remaining_cpu,

        allocatable_memory_mib: allocatable_memory,
        requested_memory_mib: requested_memory,
        remaining_memory_mib: remaining_memory,

        reliability_score: score,
        eligible,
    })
}

async fn evaluate_legacy_candidate(
    client: Client,
    candidate_node: &str,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_labels: &HashMap<String, String>,
) -> Result<ResourceAwareness> {
    let nodes: Api<Node> = Api::all(client);
    let node = nodes.get(candidate_node).await?;

    let ready = node_ready(&node);
    let schedulable = node_schedulable(&node);
    let labels_ok = labels_match(&node, required_labels);

    let (cpu_millicores, memory_mib) = node_allocatable(&node)?;

    let resources_sufficient =
        cpu_millicores >= required_cpu_millicores && memory_mib >= required_memory_mib;

    let state = if !ready || !schedulable || !labels_ok {
        ResourceState::Unavailable
    } else if !resources_sufficient {
        ResourceState::Insufficient
    } else {
        ResourceState::Available
    };

    Ok(ResourceAwareness {
        candidate_node: candidate_node.to_string(),
        state,

        node_ready: ready,
        node_schedulable: schedulable,
        labels_match: labels_ok,

        allocatable_cpu_millicores: cpu_millicores,
        requested_cpu_millicores: 0,
        remaining_cpu_millicores: cpu_millicores,
        required_cpu_millicores,

        allocatable_memory_mib: memory_mib,
        requested_memory_mib: 0,
        remaining_memory_mib: memory_mib,
        required_memory_mib,

        reliability_score: 0.0,
        multi_candidate_selection: false,
    })
}

pub async fn evaluate_resources(
    client: Client,
    candidate_node: &str,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_labels: &HashMap<String, String>,
) -> Result<ResourceAwareness> {
    let multi_candidate_selection = required_labels
        .get("failure-aware.io/role")
        .map(|value| value == "recovery-candidate")
        .unwrap_or(false);

    /*
     * Backward-compatible path.
     *
     * Old controller.json files had required_node_labels={}.
     * Those configurations continue to evaluate only
     * recovery_candidate_node exactly as before.
     */
    if !multi_candidate_selection {
        return evaluate_legacy_candidate(
            client,
            candidate_node,
            required_cpu_millicores,
            required_memory_mib,
            required_labels,
        )
        .await;
    }

    let nodes: Api<Node> = Api::all(client.clone());
    let node_list = nodes.list(&Default::default()).await?;
    let history = load_history()?;

    let mut evaluations = Vec::new();

    for node in node_list.items {
        if !labels_match(&node, required_labels) {
            continue;
        }

        let evaluation = evaluate_one_candidate(
            client.clone(),
            &node,
            required_cpu_millicores,
            required_memory_mib,
            required_labels,
            &history,
        )
        .await?;

        println!(
            "[CANDIDATE] node={} | eligible={} | Ready={} | schedulable={} | labels_match={} | alloc_cpu={}m | requested_cpu={}m | remaining_cpu={}m | required_cpu={}m | alloc_memory={}Mi | requested_memory={}Mi | remaining_memory={}Mi | required_memory={}Mi | reliability={:.6}",
            evaluation.node_name,
            evaluation.eligible,
            evaluation.ready,
            evaluation.schedulable,
            evaluation.labels_match,
            evaluation.allocatable_cpu_millicores,
            evaluation.requested_cpu_millicores,
            evaluation.remaining_cpu_millicores,
            required_cpu_millicores,
            evaluation.allocatable_memory_mib,
            evaluation.requested_memory_mib,
            evaluation.remaining_memory_mib,
            required_memory_mib,
            evaluation.reliability_score,
        );

        evaluations.push(evaluation);
    }

    if evaluations.is_empty() {
        println!("[SELECTION] no nodes matched the recovery-candidate labels");

        return Ok(ResourceAwareness {
            candidate_node: String::new(),
            state: ResourceState::Unavailable,

            node_ready: false,
            node_schedulable: false,
            labels_match: false,

            allocatable_cpu_millicores: 0,
            requested_cpu_millicores: 0,
            remaining_cpu_millicores: 0,
            required_cpu_millicores,

            allocatable_memory_mib: 0,
            requested_memory_mib: 0,
            remaining_memory_mib: 0,
            required_memory_mib,

            reliability_score: 0.0,
            multi_candidate_selection: true,
        });
    }

    let mut eligible: Vec<CandidateEvaluation> = evaluations
        .iter()
        .filter(|candidate| candidate.eligible)
        .cloned()
        .collect();

    eligible.sort_by(|a, b| {
        b.reliability_score
            .partial_cmp(&a.reliability_score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| b.remaining_cpu_millicores.cmp(&a.remaining_cpu_millicores))
            .then_with(|| b.remaining_memory_mib.cmp(&a.remaining_memory_mib))
            .then_with(|| a.node_name.cmp(&b.node_name))
    });

    if let Some(selected) = eligible.first() {
        println!(
            "[SELECTION] selected={} | reason=highest_reliability_among_eligible | reliability={:.6} | remaining_cpu={}m | remaining_memory={}Mi",
            selected.node_name,
            selected.reliability_score,
            selected.remaining_cpu_millicores,
            selected.remaining_memory_mib,
        );

        return Ok(ResourceAwareness {
            candidate_node: selected.node_name.clone(),
            state: ResourceState::Available,

            node_ready: selected.ready,
            node_schedulable: selected.schedulable,
            labels_match: selected.labels_match,

            allocatable_cpu_millicores: selected.allocatable_cpu_millicores,
            requested_cpu_millicores: selected.requested_cpu_millicores,
            remaining_cpu_millicores: selected.remaining_cpu_millicores,
            required_cpu_millicores,

            allocatable_memory_mib: selected.allocatable_memory_mib,
            requested_memory_mib: selected.requested_memory_mib,
            remaining_memory_mib: selected.remaining_memory_mib,
            required_memory_mib,

            reliability_score: selected.reliability_score,

            multi_candidate_selection: true,
        });
    }

    let had_schedulable_candidate = evaluations
        .iter()
        .any(|candidate| candidate.ready && candidate.schedulable && candidate.labels_match);

    let state = if had_schedulable_candidate {
        ResourceState::Insufficient
    } else {
        ResourceState::Unavailable
    };

    println!(
        "[SELECTION] no eligible recovery candidate | state={:?}",
        state
    );

    Ok(ResourceAwareness {
        candidate_node: String::new(),
        state,

        node_ready: false,
        node_schedulable: false,
        labels_match: true,

        allocatable_cpu_millicores: 0,
        requested_cpu_millicores: 0,
        remaining_cpu_millicores: 0,
        required_cpu_millicores,

        allocatable_memory_mib: 0,
        requested_memory_mib: 0,
        remaining_memory_mib: 0,
        required_memory_mib,

        reliability_score: 0.0,
        multi_candidate_selection: true,
    })
}
