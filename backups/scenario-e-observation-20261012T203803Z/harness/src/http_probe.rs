use anyhow::{Result, anyhow};
use chrono::Utc;
use csv::Writer;
use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use std::env;
use std::fs::OpenOptions;
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::time::{sleep, timeout};

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

#[derive(Debug, Serialize)]
struct ClinicalObservation {
    timestamp_utc: String,
    patient_uuid: String,
    encounter_uuid: String,
    status: u16,
    latency_ms: f64,
    success: bool,
    error: String,
}

#[derive(Debug, Clone)]
struct ClinicalConfig {
    base_url: String,
    username: String,
    password: String,
    patient_uuid: String,
    encounter_uuid: String,
    observation_uuid: String,
    concept_uuid: String,
    expected_temperature: f64,
}

fn required_env(name: &str) -> Result<String> {
    let value = env::var(name).map_err(|_| anyhow!("Missing environment variable: {}", name))?;

    if value.trim().is_empty() {
        return Err(anyhow!("Environment variable {} is empty", name));
    }

    Ok(value)
}

fn clinical_config() -> Result<Option<ClinicalConfig>> {
    let profile =
        env::var("FAILURE_AWARE_WORKLOAD_PROFILE").unwrap_or_else(|_| "nginx".to_string());

    match profile.as_str() {
        "nginx" => Ok(None),
        "openmrs" => Ok(Some(ClinicalConfig {
            base_url: required_env("OPENMRS_BASE_URL")?,
            username: required_env("OPENMRS_USERNAME")?,
            password: required_env("OPENMRS_PASSWORD")?,
            patient_uuid: required_env("OPENMRS_PATIENT_UUID")?,
            encounter_uuid: required_env("OPENMRS_ENCOUNTER_UUID")?,
            observation_uuid: required_env("OPENMRS_OBSERVATION_UUID")?,
            concept_uuid: required_env("OPENMRS_CONCEPT_UUID")?,
            expected_temperature: required_env("OPENMRS_EXPECTED_TEMPERATURE")?.parse()?,
        })),
        other => Err(anyhow!("Unsupported workload profile: {}", other)),
    }
}

fn discovery_timeout_ms() -> u64 {
    env::var("FAILURE_AWARE_DISCOVERY_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(3000)
}

async fn kubectl(args: &[&str]) -> Result<String> {
    let mut command = Command::new("kubectl");

    command.args(args).stdin(Stdio::null()).kill_on_drop(true);

    let output = timeout(
        Duration::from_millis(discovery_timeout_ms()),
        command.output(),
    )
    .await
    .map_err(|_| anyhow!("kubectl discovery timed out"))??;

    if !output.status.success() {
        return Err(anyhow!(
            "kubectl failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

async fn discover_active_node(namespace: &str, selector: &str) -> Result<Option<String>> {
    let output = kubectl(&[
        "get",
        "pods",
        "-n",
        namespace,
        "-l",
        selector,
        "-o",
        "jsonpath={range .items[?(@.status.phase==\"Running\")]}{.spec.nodeName}{\"\\n\"}{end}",
    ])
    .await?;

    Ok(output
        .lines()
        .find(|line| !line.trim().is_empty())
        .map(|line| line.trim().to_string()))
}

fn clinical_output_path(http_path: &str) -> String {
    Path::new(http_path)
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("clinical-observations.csv")
        .to_string_lossy()
        .into_owned()
}

fn validate_patient(record: &Value, config: &ClinicalConfig) -> Result<()> {
    if record["uuid"].as_str() != Some(config.patient_uuid.as_str()) {
        return Err(anyhow!("Patient UUID mismatch"));
    }

    if record["voided"].as_bool() != Some(false) {
        return Err(anyhow!("Patient is voided or voided status missing"));
    }

    Ok(())
}

fn validate_encounter(record: &Value, config: &ClinicalConfig) -> Result<()> {
    if record["uuid"].as_str() != Some(config.encounter_uuid.as_str()) {
        return Err(anyhow!("Encounter UUID mismatch"));
    }

    if record["patient"]["uuid"].as_str() != Some(config.patient_uuid.as_str()) {
        return Err(anyhow!("Encounter patient UUID mismatch"));
    }

    if record["voided"].as_bool() != Some(false) {
        return Err(anyhow!("Encounter is voided"));
    }

    let observations = record["obs"]
        .as_array()
        .ok_or_else(|| anyhow!("Encounter observations missing"))?;

    let observation = observations
        .iter()
        .find(|obs| obs["uuid"].as_str() == Some(config.observation_uuid.as_str()))
        .ok_or_else(|| anyhow!("Expected observation not found"))?;

    if observation["voided"].as_bool() != Some(false) {
        return Err(anyhow!("Observation is voided"));
    }

    if observation["concept"]["uuid"].as_str() != Some(config.concept_uuid.as_str()) {
        return Err(anyhow!("Observation concept mismatch"));
    }

    let value = observation["value"]
        .as_f64()
        .ok_or_else(|| anyhow!("Observation value is not numeric"))?;

    if (value - config.expected_temperature).abs() > 0.001 {
        return Err(anyhow!(
            "Temperature mismatch: expected {}, received {}",
            config.expected_temperature,
            value
        ));
    }

    Ok(())
}

async fn clinical_request(
    client: &Client,
    config: &ClinicalConfig,
    status: &mut u16,
) -> Result<()> {
    let base = config.base_url.trim_end_matches('/');

    let patient_url = format!("{}/ws/rest/v1/patient/{}", base, config.patient_uuid);

    let response = client
        .get(patient_url)
        .basic_auth(&config.username, Some(&config.password))
        .send()
        .await?;

    *status = response.status().as_u16();

    if !response.status().is_success() {
        return Err(anyhow!("Patient HTTP {}", status));
    }

    let patient: Value = response.json().await?;
    validate_patient(&patient, config)?;

    let encounter_url = format!(
        "{}/ws/rest/v1/encounter/{}?v=full",
        base, config.encounter_uuid
    );

    let response = client
        .get(encounter_url)
        .basic_auth(&config.username, Some(&config.password))
        .send()
        .await?;

    *status = response.status().as_u16();

    if !response.status().is_success() {
        return Err(anyhow!("Encounter HTTP {}", status));
    }

    let encounter: Value = response.json().await?;
    validate_encounter(&encounter, config)?;

    Ok(())
}

async fn run_clinical_probe(
    client: Client,
    config: ClinicalConfig,
    output_path: String,
    interval_ms: u64,
) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    println!("[CLINICAL] Clinical-data probe started");

    loop {
        let timestamp = Utc::now();
        let start = Instant::now();
        let mut status = 0;

        let result = clinical_request(&client, &config, &mut status).await;

        let observation = ClinicalObservation {
            timestamp_utc: timestamp.to_rfc3339(),
            patient_uuid: config.patient_uuid.clone(),
            encounter_uuid: config.encounter_uuid.clone(),
            status,
            latency_ms: start.elapsed().as_secs_f64() * 1000.0,
            success: result.is_ok(),
            error: result.err().map(|e| e.to_string()).unwrap_or_default(),
        };

        writer.serialize(&observation)?;
        writer.flush()?;

        println!(
            "[CLINICAL] {} | status={} | latency={:.3}ms | success={} | error={}",
            observation.timestamp_utc,
            observation.status,
            observation.latency_ms,
            observation.success,
            observation.error
        );

        sleep(Duration::from_millis(interval_ms)).await;
    }
}

async fn run_standard_http_probe(
    config: HarnessConfig,
    output_path: String,
    client: Client,
) -> Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(output_path)?;

    let mut writer = Writer::from_writer(file);

    loop {
        let timestamp = Utc::now();

        let active_node = discover_active_node(&config.namespace, &config.pod_label_selector).await;

        let (node, target_url, discovery_error) = match active_node {
            Ok(Some(node)) => match config.service_url_for_node(&node) {
                Some(url) => (node, url, String::new()),
                None => (
                    node.clone(),
                    String::new(),
                    format!("no service target configured for node {}", node),
                ),
            },
            Ok(None) => (
                String::new(),
                String::new(),
                "no Running workload pod found".to_string(),
            ),
            Err(error) => (
                String::new(),
                String::new(),
                format!("placement lookup failed: {}", error),
            ),
        };

        let start = Instant::now();

        let observation = if target_url.is_empty() {
            HttpObservation {
                timestamp_utc: timestamp.to_rfc3339(),
                node,
                target_url,
                status: 0,
                latency_ms: 0.0,
                success: false,
                error: discovery_error,
            }
        } else {
            match client.get(&target_url).send().await {
                Ok(response) => HttpObservation {
                    timestamp_utc: timestamp.to_rfc3339(),
                    node,
                    target_url,
                    status: response.status().as_u16(),
                    latency_ms: start.elapsed().as_secs_f64() * 1000.0,
                    success: response.status().is_success(),
                    error: String::new(),
                },
                Err(error) => HttpObservation {
                    timestamp_utc: timestamp.to_rfc3339(),
                    node,
                    target_url,
                    status: 0,
                    latency_ms: start.elapsed().as_secs_f64() * 1000.0,
                    success: false,
                    error: error.to_string(),
                },
            }
        };

        writer.serialize(&observation)?;
        writer.flush()?;

        println!(
            "[HTTP] {} | node={} | status={} | latency={:.3}ms | success={} | error={}",
            observation.timestamp_utc,
            observation.node,
            observation.status,
            observation.latency_ms,
            observation.success,
            observation.error
        );

        sleep(Duration::from_millis(config.request_interval_ms)).await;
    }
}

pub async fn run_http_probe(config: HarnessConfig, output_path: String) -> Result<()> {
    let clinical = clinical_config()?;

    let client = Client::builder()
        .timeout(Duration::from_millis(config.request_timeout_ms))
        .build()?;

    match clinical {
        None => run_standard_http_probe(config, output_path, client).await,

        Some(clinical_config) => {
            let clinical_path = clinical_output_path(&output_path);
            let interval_ms = config.request_interval_ms;

            // Both probes remain supervised by this task.
            // A failure in either probe stops the combined task.
            tokio::try_join!(
                run_standard_http_probe(config, output_path, client.clone()),
                run_clinical_probe(client, clinical_config, clinical_path, interval_ms)
            )?;

            Ok(())
        }
    }
}
