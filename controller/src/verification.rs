use anyhow::Result;
use chrono::{DateTime, Utc};
use reqwest::Client;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct VerificationResult {
    pub checked_at: DateTime<Utc>,
    pub reachable: bool,
    pub http_status: Option<u16>,
    pub latency_ms: f64,
    pub error: Option<String>,
}

pub async fn verify_http(
    url: &str,
    timeout_ms: u64,
) -> Result<VerificationResult> {
    let client = Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()?;

    let checked_at = Utc::now();
    let start = Instant::now();

    let result = client
        .get(url)
        .send()
        .await;

    let latency_ms =
        start.elapsed().as_secs_f64() * 1000.0;

    match result {
        Ok(response) => {
            let status =
                response.status().as_u16();

            Ok(VerificationResult {
                checked_at,
                reachable:
                    response.status().is_success(),
                http_status: Some(status),
                latency_ms,
                error: None,
            })
        }

        Err(error) => {
            Ok(VerificationResult {
                checked_at,
                reachable: false,
                http_status: None,
                latency_ms,
                error: Some(error.to_string()),
            })
        }
    }
}