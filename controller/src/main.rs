mod config;
mod suspicion;
mod verification;

use anyhow::Result;
use config::ControllerConfig;
use kube::Client;

#[tokio::main]
async fn main() -> Result<()> {
    let config_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/config/controller.json"
    );

    let config =
        ControllerConfig::load(config_path)?;

    println!(
        "Starting Failure-Aware Controller"
    );

    println!(
        "Target node: {}",
        config.target_node
    );

    println!(
        "Native suspicion trigger: Ready={}",
        config.trigger_ready_status
    );

    println!(
        "Verification URL: {}",
        config.verification_url
    );

    println!(
        "Verification timeout: {} ms",
        config.verification_timeout_ms
    );

    let client =
        Client::try_default().await?;

    println!(
        "Connected to Kubernetes API"
    );

    suspicion::run_suspicion_listener(
        client,
        config.target_node,
        config.trigger_ready_status,
        config.verification_url,
        config.verification_timeout_ms,
    )
    .await?;

    Ok(())
}