use anyhow::Result;
use chrono::Utc;
use csv::Writer;
use reqwest::Client;
use serde::Serialize;
use std::fs::OpenOptions;
use std::process::Command;
use std::time::Duration;
use tokio::time::sleep;

use crate::config::HarnessConfig;

#[derive(Debug, Serialize)]
struct HttpObservation {
    timestamp_utc: String,
    node: String,
    target_url: String,
    status: u16,
    latency_ms: f64,
    success: bool,
    error: String,
}

fn kubectl(
    args: &[&str],
) -> Result<String> {
    let output =
        Command::new("kubectl")
            .args(args)
            .output()?;

    if !output.status.success() {
        return Err(
            anyhow::anyhow!(
                "kubectl failed: {}",
                String::from_utf8_lossy(
                    &output.stderr
                )
            )
        );
    }

    Ok(
        String::from_utf8_lossy(
            &output.stdout
        )
        .trim()
        .to_string()
    )
}

fn discover_active_node(
    namespace: &str,
    pod_label_selector: &str,
) -> Result<Option<String>> {
    let output =
        kubectl(
            &[
                "get",
                "pods",
                "-n",
                namespace,
                "-l",
                pod_label_selector,
                "-o",
                "jsonpath={range .items[?(@.status.phase==\"Running\")]}{.spec.nodeName}{\"\\n\"}{end}",
            ]
        )?;

    let active_node =
        output
            .lines()
            .find(
                |line| {
                    !line.trim().is_empty()
                }
            )
            .map(
                |line| {
                    line.trim().to_string()
                }
            );

    Ok(active_node)
}

pub async fn run_http_probe(
    config: HarnessConfig,
    output_path: String,
) -> Result<()> {
    let file =
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(output_path)?;

    let mut writer =
        Writer::from_writer(file);

    let client =
        Client::builder()
            .timeout(
                Duration::from_millis(
                    config.request_timeout_ms
                )
            )
            .build()?;

    loop {
        let timestamp =
            Utc::now();

        let active_node =
            discover_active_node(
                &config.namespace,
                &config.pod_label_selector,
            );

        match active_node {
            Ok(Some(node)) => {
                let target_url =
                    config
                        .service_url_for_node(
                            &node
                        );

                match target_url {
                    Some(url) => {
                        let start =
                            std::time::Instant::now();

                        let result =
                            client
                                .get(&url)
                                .send()
                                .await;

                        let latency_ms =
                            start
                                .elapsed()
                                .as_secs_f64()
                                * 1000.0;

                        match result {
                            Ok(response) => {
                                let status =
                                    response
                                        .status()
                                        .as_u16();

                                let success =
                                    response
                                        .status()
                                        .is_success();

                                let observation =
                                    HttpObservation {
                                        timestamp_utc:
                                            timestamp
                                                .to_rfc3339(),

                                        node:
                                            node.clone(),

                                        target_url:
                                            url.clone(),

                                        status,

                                        latency_ms,

                                        success,

                                        error:
                                            String::new(),
                                    };

                                writer
                                    .serialize(
                                        &observation
                                    )?;

                                writer.flush()?;

                                println!(
                                    "[HTTP] {} | node={} | target={} | status={} | latency={:.3} ms | success={}",
                                    timestamp.to_rfc3339(),
                                    node,
                                    url,
                                    status,
                                    latency_ms,
                                    success
                                );
                            }

                            Err(error) => {
                                let observation =
                                    HttpObservation {
                                        timestamp_utc:
                                            timestamp
                                                .to_rfc3339(),

                                        node:
                                            node.clone(),

                                        target_url:
                                            url.clone(),

                                        status: 0,

                                        latency_ms,

                                        success: false,

                                        error:
                                            error.to_string(),
                                    };

                                writer
                                    .serialize(
                                        &observation
                                    )?;

                                writer.flush()?;

                                println!(
                                    "[HTTP] {} | node={} | target={} | status=0 | latency={:.3} ms | success=false | error={}",
                                    timestamp.to_rfc3339(),
                                    node,
                                    url,
                                    latency_ms,
                                    error
                                );
                            }
                        }
                    }

                    None => {
                        let observation =
                            HttpObservation {
                                timestamp_utc:
                                    timestamp
                                        .to_rfc3339(),

                                node:
                                    node.clone(),

                                target_url:
                                    String::new(),

                                status: 0,

                                latency_ms: 0.0,

                                success: false,

                                error:
                                    format!(
                                        "no service target configured for node {}",
                                        node
                                    ),
                            };

                        writer
                            .serialize(
                                &observation
                            )?;

                        writer.flush()?;

                        println!(
                            "[HTTP] {} | node={} | no configured service target",
                            timestamp.to_rfc3339(),
                            node
                        );
                    }
                }
            }

            Ok(None) => {
                let observation =
                    HttpObservation {
                        timestamp_utc:
                            timestamp
                                .to_rfc3339(),

                        node:
                            String::new(),

                        target_url:
                            String::new(),

                        status: 0,

                        latency_ms: 0.0,

                        success: false,

                        error:
                            "no Running workload pod found"
                                .to_string(),
                    };

                writer
                    .serialize(
                        &observation
                    )?;

                writer.flush()?;

                println!(
                    "[HTTP] {} | no Running workload pod found",
                    timestamp.to_rfc3339()
                );
            }

            Err(error) => {
                let observation =
                    HttpObservation {
                        timestamp_utc:
                            timestamp
                                .to_rfc3339(),

                        node:
                            String::new(),

                        target_url:
                            String::new(),

                        status: 0,

                        latency_ms: 0.0,

                        success: false,

                        error:
                            error.to_string(),
                    };

                writer
                    .serialize(
                        &observation
                    )?;

                writer.flush()?;

                println!(
                    "[HTTP] {} | placement lookup failed | error={}",
                    timestamp.to_rfc3339(),
                    error
                );
            }
        }

        sleep(
            Duration::from_millis(
                config.request_interval_ms
            )
        )
        .await;
    }
}