mod config;
mod http_probe;
mod kubernetes;

use anyhow::Result;
use chrono::Utc;
use config::HarnessConfig;
use serde_json::json;
use std::fs;

#[tokio::main]
async fn main() -> Result<()> {
    let default_config_path = format!("{}/config/scenario-b.json", env!("CARGO_MANIFEST_DIR"));

    let config_path = std::env::var("HARNESS_CONFIG").unwrap_or(default_config_path);

    let config = HarnessConfig::load(&config_path)?;

    println!("Starting harness for scenario: {}", config.scenario);

    println!("Target node: {}", config.target_node);

    println!("Namespace: {}", config.namespace);

    println!("Pod label selector: {}", config.pod_label_selector);

    println!("Service targets:");

    for target in &config.service_targets {
        println!("  {} -> {}", target.node, target.url);
    }

    let start_time = Utc::now();

    let run_id = format!("run-{}", start_time.format("%Y%m%dT%H%M%SZ"));

    let output_dir = format!(
        "{}/../experiments/baseline/{}/runs/{}",
        env!("CARGO_MANIFEST_DIR"),
        config.scenario,
        run_id
    );

    fs::create_dir_all(&output_dir)?;

    println!("Run ID: {}", run_id);

    println!("Output directory: {}", output_dir);

    let metadata = json!({
        "run_id": run_id,
        "scenario": config.scenario,
        "start_time_utc": start_time.to_rfc3339(),

        "target_node": config.target_node,
        "namespace": config.namespace,
        "pod_label_selector": config.pod_label_selector,

        "request_interval_ms":
            config.request_interval_ms,

        "request_timeout_ms":
            config.request_timeout_ms,

        "service_targets":
            config.service_targets
    });

    fs::write(
        format!("{}/metadata.json", output_dir),
        serde_json::to_string_pretty(&metadata)?,
    )?;

    let http_output = format!("{}/http-observations.csv", output_dir);

    let node_output = format!("{}/node-observations.csv", output_dir);

    let lease_output = format!("{}/lease-observations.csv", output_dir);

    let pod_output = format!("{}/pod-observations.csv", output_dir);

    let taint_output = format!("{}/taint-observations.csv", output_dir);

    let event_output = format!("{}/event-observations.csv", output_dir);

    let http_config = config.clone();

    let target_node_for_node = config.target_node.clone();

    let target_node_for_lease = config.target_node.clone();

    let target_node_for_taint = config.target_node.clone();

    let target_node_for_events = config.target_node.clone();

    let namespace = config.namespace.clone();

    let pod_label_selector = config.pod_label_selector.clone();

    let mut http_task =
        tokio::spawn(async move { http_probe::run_http_probe(http_config, http_output).await });

    let mut node_task =
        tokio::spawn(
            async move { kubernetes::observe_node(&target_node_for_node, node_output).await },
        );

    let mut lease_task = tokio::spawn(async move {
        kubernetes::observe_lease(&target_node_for_lease, lease_output).await
    });

    let mut pod_task = tokio::spawn(async move {
        kubernetes::observe_pod(&namespace, &pod_label_selector, pod_output).await
    });

    let mut taint_task = tokio::spawn(async move {
        kubernetes::observe_taint(&target_node_for_taint, taint_output).await
    });

    let mut event_task = tokio::spawn(async move {
        kubernetes::observe_events(&target_node_for_events, event_output).await
    });

    tokio::select! {
        result = &mut http_task => {
            println!(
                "HTTP task stopped: {:?}",
                result
            );
        }

        result = &mut node_task => {
            println!(
                "Node task stopped: {:?}",
                result
            );
        }

        result = &mut lease_task => {
            println!(
                "Lease task stopped: {:?}",
                result
            );
        }

        result = &mut pod_task => {
            println!(
                "Pod task stopped: {:?}",
                result
            );
        }

        result = &mut taint_task => {
            println!(
                "Taint task stopped: {:?}",
                result
            );
        }

        result = &mut event_task => {
            println!(
                "Event task stopped: {:?}",
                result
            );
        }

        _ = tokio::signal::ctrl_c() => {
            println!();
            println!(
                "Shutdown requested."
            );
        }
    }

    http_task.abort();
    node_task.abort();
    lease_task.abort();
    pod_task.abort();
    taint_task.abort();
    event_task.abort();

    println!("Harness stopped. Results saved under:");

    println!("{}", output_dir);

    Ok(())
}
