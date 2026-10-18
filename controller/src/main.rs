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

use anyhow::{Context, Result};
use config::ControllerConfig;
use kube::Client;
use std::env;
use std::path::PathBuf;

fn configure_node_history() -> Result<PathBuf> {
    let path = env::var("FAILURE_AWARE_NODE_HISTORY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/config/node-history-runtime.json"
            ))
        });

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!(
                "Failed to create node-history directory: {}",
                parent.display()
            )
        })?;
    }

    if !path.exists() {
        std::fs::write(&path, "{}\n").with_context(|| {
            format!("Failed to initialize node-history file: {}", path.display())
        })?;
    }

    // resource.rs reads this environment variable.
    //
    // Set it before starting either the collector or
    // the suspicion listener.
    unsafe {
        env::set_var("FAILURE_AWARE_NODE_HISTORY", path.as_os_str());
    }

    Ok(path)
}

#[tokio::main]
async fn main() -> Result<()> {
    let config_path = env::var("FAILURE_AWARE_CONTROLLER_CONFIG").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/config/controller.json").to_string()
    });

    let config = ControllerConfig::load(&config_path)?;

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
    );

    println!("Workload: {}", workload_awareness.name);

    println!("Workload type: {:?}", workload_awareness.workload_type);

    println!(
        "Duplication sensitive: {}",
        workload_awareness.duplication_sensitive
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

    println!(
        "Kubernetes API timeout: {} ms",
        config.kubernetes_api_timeout_ms
    );

    println!(
        "Resource evaluation timeout: {} ms",
        config.resource_evaluation_timeout_ms
    );

    println!("Enforcement timeout: {} ms", config.enforcement_timeout_ms);

    println!("Fencing timeout: {} ms", config.fencing_timeout_ms);

    println!("Fencing supported: {}", config.fencing_supported);

    println!(
        "Fencing command configured: {}",
        !config.fencing_command.trim().is_empty()
    );

    /*
     * Configure the runtime node-history location before
     * starting the asynchronous controller tasks.
     *
     * Existing synthetic history remains untouched.
     */
    let history_path = configure_node_history()?;

    println!("[HISTORY] Runtime history file: {}", history_path.display());

    let client = Client::try_default().await?;

    println!("Connected to Kubernetes API");

    /*
     * Start the node-history collector.
     *
     * It operates independently of recovery decisions.
     * Its Kubernetes API calls are bounded in resource.rs.
     *
     * The collector records observations but does not
     * initiate recovery or modify workloads.
     */
    let history_client = client.clone();

    let history_task = tokio::spawn(async move {
        if let Err(error) = resource::run_node_history_collector(history_client).await {
            eprintln!("[HISTORY FATAL] Collector terminated: {}", error);
        }
    });

    println!("[HISTORY] Background collection task started");

    /*
     * Preserve the existing suspicion listener and
     * controller decision flow.
     */
    let listener_result = suspicion::run_suspicion_listener(
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
        config.resource_evaluation_timeout_ms,
        config.enforcement_timeout_ms,
    )
    .await;

    /*
     * Stop the collector when the suspicion listener exits.
     */
    history_task.abort();

    listener_result?;

    Ok(())
}
