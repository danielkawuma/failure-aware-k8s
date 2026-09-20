use anyhow::Result;
use chrono::Utc;
use csv::Writer;
use reqwest::Client;
use serde::Serialize;
use std::fs::OpenOptions;
use std::time::{Duration, Instant};
use tokio::time::sleep;

use crate::config::HarnessConfig;

#[derive(Serialize)]
struct HttpObservation {
    timestamp_utc: String,
    http_status: u16,
    latency_ms: f64,
    success: bool,
    error: String,
}

pub async fn run_http_probe(
    config: HarnessConfig,
    output_path: String,
) -> Result<()> {
    let client = Client::builder()
        .timeout(Duration::from_millis(
            config.request_timeout_ms,
        ))
        .build()?;

    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();
        let start = Instant::now();

        let result = client
            .get(&config.target_url)
            .send()
            .await;

        let latency_ms =
            start.elapsed().as_secs_f64() * 1000.0;

        match result {
            Ok(response) => {
                let status = response.status().as_u16();
                let success = response.status().is_success();

                let observation = HttpObservation {
                    timestamp_utc: timestamp.to_rfc3339(),
                    http_status: status,
                    latency_ms,
                    success,
                    error: String::new(),
                };

                writer.serialize(&observation)?;
                writer.flush()?;

                println!(
                    "[HTTP] {} | status={} | latency={:.3} ms",
                    timestamp.to_rfc3339(),
                    status,
                    latency_ms
                );
            }

            Err(error) => {
                let error_message = error.to_string();

                let observation = HttpObservation {
                    timestamp_utc: timestamp.to_rfc3339(),
                    http_status: 0,
                    latency_ms,
                    success: false,
                    error: error_message.clone(),
                };

                writer.serialize(&observation)?;
                writer.flush()?;

                println!(
                    "[HTTP] {} | FAILED | latency={:.3} ms | error={}",
                    timestamp.to_rfc3339(),
                    latency_ms,
                    error_message
                );
            }
        }

        sleep(Duration::from_millis(
            config.request_interval_ms,
        ))
        .await;
    }
}