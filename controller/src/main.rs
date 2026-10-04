mod awareness;
mod config;
mod decision;
mod enforcement;
mod fencing;
mod recovery_safety;
mod resource;
mod suspicion;
mod verification;
mod workload;

use anyhow::Result;
use config::ControllerConfig;
use kube::Client;

#[tokio::main]
async fn main() -> Result<()> {
    let config_path = concat!(env!("CARGO_MANIFEST_DIR"), "/config/controller.json");

    let config = ControllerConfig::load(config_path)?;

    println!("Starting Failure-Aware Controller");

    println!("Target node: {}", config.target_node);

    println!(
        "Native suspicion trigger: Ready={}",
        config.trigger_ready_status
    );

    println!("Verification URL: {}", config.verification_url);

    println!(
        "Verification timeout: {} ms",
        config.verification_timeout_ms
    );

    println!("Verification attempts: {}", config.verification_attempts);

    println!(
        "Verification interval: {} ms",
        config.verification_interval_ms
    );

    let workload_awareness = workload::WorkloadAwareness::new(
        config.workload_name.clone(),
        config.workload_type.clone(),
        config.duplication_sensitive,
        config.service_criticality.clone(),
    );

    println!("Workload: {}", workload_awareness.name);

    println!("Workload type: {:?}", workload_awareness.workload_type);

    println!(
        "Duplication sensitive: {}",
        workload_awareness.duplication_sensitive
    );

    println!(
        "Service criticality: {:?}",
        workload_awareness.service_criticality
    );

    println!("Namespace: {}", config.namespace);

    println!("Pod label selector: {}", config.pod_label_selector);

    println!("Recovery candidate: {}", config.recovery_candidate_node);

    println!("Required recovery CPU: {}m", config.required_cpu_millicores);

    println!(
        "Required recovery memory: {} MiB",
        config.required_memory_mib
    );

    println!(
        "Required recovery node labels: {:?}",
        config.required_node_labels
    );

    println!("Fencing supported: {}", config.fencing_supported);

    println!(
        "Fencing command: {}",
        if config.fencing_command.is_empty() {
            "<none>"
        } else {
            &config.fencing_command
        }
    );

    let client = Client::try_default().await?;

    println!("Connected to Kubernetes API");

    suspicion::run_suspicion_listener(
        client,
        config.target_node,
        config.trigger_ready_status,
        config.verification_url,
        config.verification_timeout_ms,
        config.verification_attempts,
        config.verification_interval_ms,
        workload_awareness,
        config.namespace,
        config.pod_label_selector,
        config.recovery_candidate_node,
        config.required_cpu_millicores,
        config.required_memory_mib,
        config.required_node_labels,
        config.fencing_supported,
        config.fencing_command,
    )
    .await?;

    Ok(())
}
