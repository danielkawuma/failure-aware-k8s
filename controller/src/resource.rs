use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, Utc};
use k8s_openapi::api::core::v1::{Node, Pod};
use kube::{Api, Client};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::{sleep, timeout};

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

#[derive(Debug, Clone, Serialize, Deserialize)]
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

impl Default for NodeHistory {
    fn default() -> Self {
        Self {
            uptime_ratio: default_uptime_ratio(),
            recent_failures: 0,
            successful_recoveries: 0,
            failed_recoveries: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeObservation {
    timestamp_utc: DateTime<Utc>,
    node: String,
    ready_status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct ObservationState {
    nodes: HashMap<String, NodeObservation>,
}

fn ready_status(node: &Node) -> String {
    node.status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .and_then(|conditions| {
            conditions
                .iter()
                .find(|condition| condition.type_ == "Ready")
        })
        .map(|condition| condition.status.clone())
        .unwrap_or_else(|| "Unknown".to_string())
}

fn node_ready(node: &Node) -> bool {
    ready_status(node) == "True"
}

fn node_schedulable(node: &Node) -> bool {
    !node
        .spec
        .as_ref()
        .and_then(|spec| spec.unschedulable)
        .unwrap_or(false)
}

fn labels_match(node: &Node, required_labels: &HashMap<String, String>) -> bool {
    required_labels.iter().all(|(key, expected)| {
        node.metadata
            .labels
            .as_ref()
            .and_then(|labels| labels.get(key))
            == Some(expected)
    })
}

fn api_timeout_ms() -> u64 {
    env::var("FAILURE_AWARE_API_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(3000)
}

async fn bounded_api<T, F>(operation: &str, future: F) -> Result<T>
where
    F: std::future::Future<Output = Result<T>>,
{
    let timeout_ms = api_timeout_ms();

    timeout(Duration::from_millis(timeout_ms), future)
        .await
        .map_err(|_| anyhow!("{} timed out after {} ms", operation, timeout_ms))?
        .with_context(|| format!("Kubernetes API operation failed: {}", operation))
}

fn parse_cpu_millicores(value: &str) -> Result<u64> {
    if let Some(nano) = value.strip_suffix('n') {
        let nano: u64 = nano.parse()?;
        return Ok(nano.saturating_add(999_999) / 1_000_000);
    }

    if let Some(micro) = value.strip_suffix('u') {
        let micro: u64 = micro.parse()?;
        return Ok(micro.saturating_add(999) / 1_000);
    }

    if let Some(milli) = value.strip_suffix('m') {
        return Ok(milli.parse()?);
    }

    let cores: f64 = value.parse()?;

    if !cores.is_finite() || cores < 0.0 {
        return Err(anyhow!("Invalid CPU quantity: {}", value));
    }

    Ok((cores * 1000.0).ceil() as u64)
}

fn parse_memory_mib(value: &str) -> Result<u64> {
    let units = [
        ("Ki", 1024.0),
        ("Mi", 1024.0_f64.powi(2)),
        ("Gi", 1024.0_f64.powi(3)),
        ("Ti", 1024.0_f64.powi(4)),
        ("Pi", 1024.0_f64.powi(5)),
        ("Ei", 1024.0_f64.powi(6)),
        ("K", 1000.0),
        ("M", 1000.0_f64.powi(2)),
        ("G", 1000.0_f64.powi(3)),
        ("T", 1000.0_f64.powi(4)),
        ("P", 1000.0_f64.powi(5)),
        ("E", 1000.0_f64.powi(6)),
    ];

    for (suffix, multiplier) in units {
        if let Some(number) = value.strip_suffix(suffix) {
            let amount: f64 = number.parse()?;

            if !amount.is_finite() || amount < 0.0 {
                return Err(anyhow!("Invalid memory quantity: {}", value));
            }

            return Ok((amount * multiplier / 1024.0 / 1024.0).ceil() as u64);
        }
    }

    let bytes: f64 = value.parse()?;

    if !bytes.is_finite() || bytes < 0.0 {
        return Err(anyhow!("Invalid memory quantity: {}", value));
    }

    Ok((bytes / 1024.0 / 1024.0).ceil() as u64)
}

fn node_allocatable(node: &Node) -> Result<(u64, u64)> {
    let name = node.metadata.name.as_deref().unwrap_or("<unknown>");

    let allocatable = node
        .status
        .as_ref()
        .and_then(|status| status.allocatable.as_ref())
        .ok_or_else(|| anyhow!("Node {} has no allocatable resources", name))?;

    let cpu = allocatable
        .get("cpu")
        .ok_or_else(|| anyhow!("Missing allocatable CPU"))?;

    let memory = allocatable
        .get("memory")
        .ok_or_else(|| anyhow!("Missing allocatable memory"))?;

    Ok((parse_cpu_millicores(&cpu.0)?, parse_memory_mib(&memory.0)?))
}

fn container_requests(pod: &Pod) -> Result<(u64, u64)> {
    let Some(spec) = pod.spec.as_ref() else {
        return Ok((0, 0));
    };

    let mut app_cpu = 0u64;
    let mut app_memory = 0u64;

    for container in &spec.containers {
        if let Some(requests) = container
            .resources
            .as_ref()
            .and_then(|resources| resources.requests.as_ref())
        {
            if let Some(cpu) = requests.get("cpu") {
                app_cpu = app_cpu.saturating_add(parse_cpu_millicores(&cpu.0)?);
            }

            if let Some(memory) = requests.get("memory") {
                app_memory = app_memory.saturating_add(parse_memory_mib(&memory.0)?);
            }
        }
    }

    let mut max_init_cpu = 0u64;
    let mut max_init_memory = 0u64;

    if let Some(init_containers) = spec.init_containers.as_ref() {
        for container in init_containers {
            let mut cpu = 0u64;
            let mut memory = 0u64;

            if let Some(requests) = container
                .resources
                .as_ref()
                .and_then(|resources| resources.requests.as_ref())
            {
                if let Some(value) = requests.get("cpu") {
                    cpu = parse_cpu_millicores(&value.0)?;
                }

                if let Some(value) = requests.get("memory") {
                    memory = parse_memory_mib(&value.0)?;
                }
            }

            max_init_cpu = max_init_cpu.max(cpu);
            max_init_memory = max_init_memory.max(memory);
        }
    }

    let mut cpu = app_cpu.max(max_init_cpu);
    let mut memory = app_memory.max(max_init_memory);

    if let Some(overhead) = spec.overhead.as_ref() {
        if let Some(value) = overhead.get("cpu") {
            cpu = cpu.saturating_add(parse_cpu_millicores(&value.0)?);
        }

        if let Some(value) = overhead.get("memory") {
            memory = memory.saturating_add(parse_memory_mib(&value.0)?);
        }
    }

    Ok((cpu, memory))
}

async fn requested_resources_by_node(client: Client) -> Result<HashMap<String, (u64, u64)>> {
    let pods: Api<Pod> = Api::all(client);

    let pod_list = bounded_api("list all Pods", async {
        Ok(pods.list(&Default::default()).await?)
    })
    .await?;

    let mut usage: HashMap<String, (u64, u64)> = HashMap::new();

    for pod in pod_list.items {
        let phase = pod
            .status
            .as_ref()
            .and_then(|status| status.phase.as_deref())
            .unwrap_or("");

        if phase == "Succeeded" || phase == "Failed" {
            continue;
        }

        let Some(node_name) = pod.spec.as_ref().and_then(|spec| spec.node_name.as_ref()) else {
            continue;
        };

        let (cpu, memory) = container_requests(&pod)?;

        let entry = usage.entry(node_name.clone()).or_insert((0, 0));

        entry.0 = entry.0.saturating_add(cpu);
        entry.1 = entry.1.saturating_add(memory);
    }

    Ok(usage)
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

fn history_path() -> PathBuf {
    if let Ok(configured) = env::var("FAILURE_AWARE_NODE_HISTORY") {
        return PathBuf::from(configured);
    }

    let primary = PathBuf::from("controller/config/node-history.json");

    if primary.exists() {
        primary
    } else {
        PathBuf::from("config/node-history.json")
    }
}

fn load_history() -> Result<HashMap<String, NodeHistory>> {
    let path = history_path();

    if !path.exists() {
        println!("[RELIABILITY] history file not found; using neutral defaults");
        return Ok(HashMap::new());
    }

    let contents = fs::read_to_string(&path)?;
    let history = serde_json::from_str(&contents)?;

    Ok(history)
}

fn save_history(history: &HashMap<String, NodeHistory>) -> Result<()> {
    let path = history_path();

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let temporary = path.with_extension("json.tmp");

    fs::write(&temporary, serde_json::to_string_pretty(history)?)?;

    fs::rename(temporary, path)?;

    Ok(())
}

fn observations_path() -> PathBuf {
    history_path().with_file_name("node-observations.jsonl")
}

fn observation_state_path() -> PathBuf {
    history_path().with_file_name("node-observation-state.json")
}

fn append_observation(observation: &NodeObservation) -> Result<()> {
    let path = observations_path();

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;

    writeln!(file, "{}", serde_json::to_string(observation)?)?;

    Ok(())
}

fn load_observation_state() -> Result<ObservationState> {
    let path = observation_state_path();

    if !path.exists() {
        return Ok(ObservationState::default());
    }

    Ok(serde_json::from_str(&fs::read_to_string(path)?)?)
}

fn save_observation_state(state: &ObservationState) -> Result<()> {
    let path = observation_state_path();

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let temporary = path.with_extension("json.tmp");

    fs::write(&temporary, serde_json::to_string_pretty(state)?)?;

    fs::rename(temporary, path)?;

    Ok(())
}

fn update_history_from_observations(
    nodes: &[Node],
    history: &mut HashMap<String, NodeHistory>,
    state: &mut ObservationState,
) -> Result<()> {
    let now = Utc::now();

    for node in nodes {
        let Some(name) = node.metadata.name.as_ref() else {
            continue;
        };

        let status = ready_status(node);
        let previous = state.nodes.get(name).cloned();

        if let Some(previous) = previous.as_ref() {
            if previous.ready_status == "True" && status == "False" {
                let entry = history.entry(name.clone()).or_default();

                entry.recent_failures = entry.recent_failures.saturating_add(1);
            }
        }

        let observation = NodeObservation {
            timestamp_utc: now,
            node: name.clone(),
            ready_status: status,
        };

        append_observation(&observation)?;
        state.nodes.insert(name.clone(), observation);
    }

    Ok(())
}

fn recompute_uptime_ratios(history: &mut HashMap<String, NodeHistory>) -> Result<()> {
    let path = observations_path();

    if !path.exists() {
        return Ok(());
    }

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);

    let mut by_node: HashMap<String, Vec<NodeObservation>> = HashMap::new();

    for line in reader.lines() {
        let line = line?;

        if line.trim().is_empty() {
            continue;
        }

        let observation: NodeObservation = serde_json::from_str(&line)?;

        by_node
            .entry(observation.node.clone())
            .or_default()
            .push(observation);
    }

    for (node, mut observations) in by_node {
        observations.sort_by_key(|o| o.timestamp_utc);

        let mut ready_ms: i64 = 0;
        let mut known_ms: i64 = 0;

        for pair in observations.windows(2) {
            let first = &pair[0];
            let second = &pair[1];

            let elapsed = (second.timestamp_utc - first.timestamp_utc).num_milliseconds();

            if elapsed <= 0 || elapsed > 60_000 {
                continue;
            }

            match first.ready_status.as_str() {
                "True" => {
                    ready_ms += elapsed;
                    known_ms += elapsed;
                }

                "False" => {
                    known_ms += elapsed;
                }

                _ => {}
            }
        }

        if known_ms > 0 {
            let entry = history.entry(node).or_default();

            entry.uptime_ratio = ready_ms as f64 / known_ms as f64;
        }
    }

    Ok(())
}

pub async fn run_node_history_collector(client: Client) -> Result<()> {
    let nodes: Api<Node> = Api::all(client);

    println!("[HISTORY] Dynamic node-history collector started");

    loop {
        let result: Result<()> = async {
            let node_list = bounded_api("node-history Node listing", async {
                Ok(nodes.list(&Default::default()).await?)
            })
            .await?;

            let mut history = load_history()?;
            let mut state = load_observation_state()?;

            update_history_from_observations(&node_list.items, &mut history, &mut state)?;

            recompute_uptime_ratios(&mut history)?;

            save_history(&history)?;
            save_observation_state(&state)?;

            println!(
                "[HISTORY] {} | nodes={} | history_updated=true",
                Utc::now().to_rfc3339(),
                node_list.items.len()
            );

            Ok(())
        }
        .await;

        if let Err(error) = result {
            println!("[HISTORY ERROR] {} | {}", Utc::now().to_rfc3339(), error);
        }

        sleep(Duration::from_secs(30)).await;
    }
}

pub fn record_recovery_outcome(node_name: &str, successful: bool) -> Result<()> {
    let mut history = load_history()?;

    let entry = history.entry(node_name.to_string()).or_default();

    if successful {
        entry.successful_recoveries = entry.successful_recoveries.saturating_add(1);
    } else {
        entry.failed_recoveries = entry.failed_recoveries.saturating_add(1);
    }

    save_history(&history)?;

    Ok(())
}

fn evaluate_one_candidate(
    node: &Node,
    required_cpu_millicores: u64,
    required_memory_mib: u64,
    required_labels: &HashMap<String, String>,
    history: &HashMap<String, NodeHistory>,
    usage: &HashMap<String, (u64, u64)>,
) -> Result<CandidateEvaluation> {
    let node_name = node
        .metadata
        .name
        .clone()
        .ok_or_else(|| anyhow!("Candidate node has no name"))?;

    let ready = node_ready(node);
    let schedulable = node_schedulable(node);
    let labels_ok = labels_match(node, required_labels);

    let (allocatable_cpu, allocatable_memory) = node_allocatable(node)?;

    let (requested_cpu, requested_memory) = usage.get(&node_name).copied().unwrap_or((0, 0));

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

    let node = bounded_api("legacy candidate Node GET", async {
        Ok(nodes.get(candidate_node).await?)
    })
    .await?;

    let ready = node_ready(&node);
    let schedulable = node_schedulable(&node);
    let labels_ok = labels_match(&node, required_labels);

    let (cpu, memory) = node_allocatable(&node)?;

    let sufficient = cpu >= required_cpu_millicores && memory >= required_memory_mib;

    let state = if !ready || !schedulable || !labels_ok {
        ResourceState::Unavailable
    } else if !sufficient {
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

        allocatable_cpu_millicores: cpu,
        requested_cpu_millicores: 0,
        remaining_cpu_millicores: cpu,
        required_cpu_millicores,

        allocatable_memory_mib: memory,
        requested_memory_mib: 0,
        remaining_memory_mib: memory,
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

    let node_list = bounded_api("recovery candidate Node listing", async {
        Ok(nodes.list(&Default::default()).await?)
    })
    .await?;

    let history = load_history()?;
    let usage = requested_resources_by_node(client).await?;

    let mut evaluations = Vec::new();

    for node in node_list.items {
        if !labels_match(&node, required_labels) {
            continue;
        }

        let evaluation = evaluate_one_candidate(
            &node,
            required_cpu_millicores,
            required_memory_mib,
            required_labels,
            &history,
            &usage,
        )?;

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
            evaluation.reliability_score
        );

        evaluations.push(evaluation);
    }

    if evaluations.is_empty() {
        println!("[SELECTION] no nodes matched recovery-candidate labels");

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
            selected.remaining_memory_mib
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
