use anyhow::Result;
use chrono::{DateTime, Utc};
use reqwest::Client;
use std::time::{Duration, Instant};
use tokio::time::sleep;

#[derive(Debug, Clone)]
pub struct VerificationResult {
    pub checked_at: DateTime<Utc>,
    pub reachable: bool,
    pub http_status: Option<u16>,
    pub latency_ms: f64,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct VerificationEvidence {
    pub attempts: u32,
    pub successes: u32,
    pub failures: u32,
    pub results: Vec<VerificationResult>,
}

pub async fn verify_http(url: &str, timeout_ms: u64) -> Result<VerificationResult> {
    let client = Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()?;

    let checked_at = Utc::now();
    let start = Instant::now();

    let result = client.get(url).send().await;

    let latency_ms = start.elapsed().as_secs_f64() * 1000.0;

    match result {
        Ok(response) => {
            let status = response.status().as_u16();

            Ok(VerificationResult {
                checked_at,
                reachable: response.status().is_success(),
                http_status: Some(status),
                latency_ms,
                error: None,
            })
        }

        Err(error) => Ok(VerificationResult {
            checked_at,
            reachable: false,
            http_status: None,
            latency_ms,
            error: Some(error.to_string()),
        }),
    }
}

pub async fn verify_http_bounded(
    url: &str,
    timeout_ms: u64,
    attempts: u32,
    interval_ms: u64,
) -> Result<VerificationEvidence> {
    let mut results = Vec::new();
    let mut successes = 0;
    let mut failures = 0;

    for attempt in 1..=attempts {
        let result = verify_http(url, timeout_ms).await?;

        if result.reachable {
            successes += 1;
        } else {
            failures += 1;
        }

        println!(
            "[VERIFY] attempt={}/{} | reachable={} | HTTP={:?} | latency={:.3} ms | error={:?}",
            attempt,
            attempts,
            result.reachable,
            result.http_status,
            result.latency_ms,
            result.error
        );

        results.push(result);

        if attempt < attempts {
            sleep(Duration::from_millis(interval_ms)).await;
        }
    }

    Ok(VerificationEvidence {
        attempts,
        successes,
        failures,
        results,
    })
}
